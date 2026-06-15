defmodule Airo.Gateway do
  @moduledoc """
  Request entry point: alias resolution → scope authorization → candidate
  selection → param normalization → adapter dispatch (DESIGN §13).

  `resolve/3` makes all the policy decisions and returns a dispatch *plan*;
  `run/1` (chat) and `run_stream/3` execute it. Splitting them lets the
  controller read transparency metadata (provider/model) from the plan *before*
  it starts streaming. Candidate *selection* here is deliberately minimal —
  enabled candidates, lowest `priority` first — since the real routing core
  (weighting, health-awareness, failover, strict pins) is S4. Usage/cost
  recording is S6.
  """

  alias Airo.Adapter
  alias Airo.Adapter.Context
  alias Airo.Config
  alias Airo.Config.{Alias, AliasCandidate, ClientKey, Deployment, Provider}
  alias Airo.Gateway.Params
  alias Airo.Registry
  alias Airo.Repo

  @type plan :: %{
          adapter: module(),
          provider: Provider.t(),
          deployment: Deployment.t(),
          alias: Alias.t(),
          context: Context.t(),
          body: map()
        }

  @type error ::
          :missing_model
          | {:model_not_found, String.t()}
          | {:forbidden, String.t()}
          | :no_deployment
          | {:no_adapter, atom()}
          | {:unsupported_capability, atom()}
          | {:http_error, non_neg_integer(), term()}
          | {:transport_error, term()}

  @doc """
  Resolve a request to a dispatch plan: validate the model, look up the alias,
  authorize the client key's scope, select an enabled candidate, pick the
  adapter, and confirm it supports `capability` (`:chat` | `:stream`). The plan
  carries the normalized upstream `body`. Returns a structured error otherwise.
  """
  @spec resolve(map(), ClientKey.t(), atom()) :: {:ok, plan()} | {:error, error()}
  def resolve(params, %ClientKey{} = client_key, capability) when is_map(params) do
    with {:ok, model} <- fetch_model(params),
         {:ok, alias_} <- fetch_alias(model),
         :ok <- authorize(client_key, model),
         {:ok, deployment, provider} <- select_candidate(alias_),
         {:ok, adapter} <- fetch_adapter(provider),
         :ok <- ensure_capability(adapter, capability) do
      {:ok,
       %{
         adapter: adapter,
         provider: provider,
         deployment: deployment,
         alias: alias_,
         context: Context.new(provider, deployment: deployment),
         body:
           Params.normalize(params, %{provider: provider, deployment: deployment, alias: alias_})
       }}
    end
  end

  @doc """
  Run a non-streaming chat completion. Convenience over `resolve/3` + `run/1`;
  returns just the OpenAI-shaped response body.
  """
  @spec chat(map(), ClientKey.t()) :: {:ok, map()} | {:error, error()}
  def chat(params, %ClientKey{} = client_key) when is_map(params) do
    with {:ok, plan} <- resolve(params, client_key, :chat), do: run(plan)
  end

  @doc "Execute a resolved plan as a non-streaming chat completion."
  @spec run(plan()) :: {:ok, map()} | {:error, error()}
  def run(%{adapter: adapter, body: body, context: context}), do: adapter.chat(body, context)

  @doc """
  Execute a resolved plan as a streaming completion, folding each normalized
  delta chunk into `acc` via `reducer` (see `Airo.Adapter.stream/4`).
  """
  @spec run_stream(plan(), acc, (map(), acc -> acc)) :: {:ok, acc} | {:error, error()}
        when acc: term()
  def run_stream(%{adapter: adapter, body: body, context: context}, acc, reducer),
    do: adapter.stream(body, context, acc, reducer)

  @doc """
  Transparency metadata for a resolved plan (DESIGN §5.1) — which concrete
  provider/model served, whether a fallback fired, and (when known) latency.
  Emitted as `x-gateway-*` headers and the streaming trailer.
  """
  @spec transparency(plan(), keyword()) :: map()
  def transparency(%{provider: provider, deployment: deployment}, extra \\ []) do
    %{
      "provider" => provider.name,
      "model" => deployment.model_name,
      "deployment_id" => deployment.id,
      "fallback_used" => Keyword.get(extra, :fallback_used, false)
    }
    |> maybe_put("latency_ms", Keyword.get(extra, :latency_ms))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_model(params) do
    case params["model"] do
      model when is_binary(model) and model != "" -> {:ok, model}
      _ -> {:error, :missing_model}
    end
  end

  defp fetch_alias(model) do
    case Config.get_alias_by_name(model) do
      %Alias{} = alias_ -> {:ok, alias_}
      nil -> {:error, {:model_not_found, model}}
    end
  end

  defp authorize(client_key, model) do
    if ClientKey.scoped?(client_key, model), do: :ok, else: {:error, {:forbidden, model}}
  end

  # S2: enabled candidates, lowest priority first, first one wins. S4 generalizes
  # this to weighted/round-robin selection with health-awareness and failover.
  defp select_candidate(%Alias{} = alias_) do
    alias_ = Repo.preload(alias_, candidates: [deployment: [provider: :credential]])

    alias_.candidates
    |> Enum.filter(&candidate_enabled?/1)
    |> Enum.sort_by(& &1.priority)
    |> List.first()
    |> case do
      %AliasCandidate{deployment: deployment} -> {:ok, deployment, deployment.provider}
      nil -> {:error, :no_deployment}
    end
  end

  defp candidate_enabled?(%AliasCandidate{
         deployment: %{enabled: dep_on, provider: %{enabled: prov_on}}
       }),
       do: dep_on and prov_on

  defp candidate_enabled?(_), do: false

  defp fetch_adapter(provider) do
    case Registry.fetch(provider.adapter_type) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, :no_adapter} -> {:error, {:no_adapter, provider.adapter_type}}
    end
  end

  defp ensure_capability(adapter, capability) do
    if Adapter.supports?(adapter, capability),
      do: :ok,
      else: {:error, {:unsupported_capability, capability}}
  end
end
