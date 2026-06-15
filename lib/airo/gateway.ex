defmodule Airo.Gateway do
  @moduledoc """
  Request entry point: alias resolution → scope authorization → candidate
  selection → param normalization → adapter dispatch (DESIGN §13).

  S2 wires the non-streaming chat path end to end. Candidate *selection* here is
  deliberately minimal — enabled candidates, lowest `priority` first — since the
  real routing core (weighting, health-awareness, failover, strict pins) is S4.
  Usage/cost recording is S6.
  """

  alias Airo.Adapter
  alias Airo.Adapter.Context
  alias Airo.Config
  alias Airo.Config.{Alias, AliasCandidate, ClientKey}
  alias Airo.Gateway.Params
  alias Airo.Registry
  alias Airo.Repo

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
  Run a non-streaming chat completion for an authenticated client key.

  `params` is the OpenAI-shaped request body (string keys); `params["model"]` is
  the logical alias. Returns the OpenAI-shaped response body or a structured
  error the controller maps to an HTTP status.
  """
  @spec chat(map(), ClientKey.t()) :: {:ok, map()} | {:error, error()}
  def chat(params, %ClientKey{} = client_key) when is_map(params) do
    with {:ok, model} <- fetch_model(params),
         {:ok, alias_} <- fetch_alias(model),
         :ok <- authorize(client_key, model),
         {:ok, deployment, provider} <- select_candidate(alias_) do
      dispatch_chat(params, alias_, deployment, provider)
    end
  end

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

  defp dispatch_chat(params, alias_, deployment, provider) do
    with {:ok, adapter} <- fetch_adapter(provider),
         :ok <- ensure_capability(adapter, :chat) do
      body =
        Params.normalize(params, %{provider: provider, deployment: deployment, alias: alias_})

      adapter.chat(body, Context.new(provider, deployment: deployment))
    end
  end

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
