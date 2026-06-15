defmodule Airo.Realtime do
  @moduledoc """
  Resolves a realtime session request to an upstream WebSocket target
  (DESIGN-realtime-and-client.md §4). Like the HTTP gateway, `model` is an alias
  or a concrete deployment id; resolution is **connect-time** (pick a healthy
  candidate now — no mid-session failover).

  Returns a parsed target the proxy hands to `Mint.WebSocket`: the upstream
  scheme/host/port/path plus the provider auth headers. The realtime *protocol*
  is a transparent pass-through — Airo brokers credentials and the network path
  (internal or external provider), it does not translate dialects.
  """

  alias Airo.Config
  alias Airo.Config.{Alias, ClientKey}
  alias Airo.{Routing, Transport}

  @type target :: %{
          ws_scheme: :ws | :wss,
          host: String.t(),
          port: :inet.port_number(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          deployment: Airo.Config.Deployment.t(),
          provider: Airo.Config.Provider.t()
        }

  @type error ::
          {:forbidden, String.t()}
          | {:model_not_found, String.t()}
          | {:unsupported_intent, String.t()}
          | :no_deployment

  # Realtime intent (query param) → the capability its deployments serve.
  @capabilities %{"transcription" => :transcription}

  @doc """
  Resolve `model` + `intent` for an authenticated client key to an upstream WS
  target, or a structured error.
  """
  @spec resolve(String.t(), ClientKey.t(), String.t()) :: {:ok, target()} | {:error, error()}
  def resolve(model, %ClientKey{} = client_key, intent) when is_binary(model) do
    with {:ok, capability} <- capability_for(intent),
         :ok <- authorize(client_key, model),
         {:ok, candidate} <- first_candidate(model, capability) do
      {:ok, target(candidate, model, intent)}
    end
  end

  defp capability_for(intent) do
    case Map.fetch(@capabilities, intent) do
      {:ok, capability} -> {:ok, capability}
      :error -> {:error, {:unsupported_intent, intent}}
    end
  end

  defp authorize(client_key, model) do
    if ClientKey.scoped?(client_key, model), do: :ok, else: {:error, {:forbidden, model}}
  end

  # Connect-time selection: the first health-ordered candidate (alias or concrete).
  defp first_candidate(model, capability) do
    case Config.get_alias_by_name(model) do
      %Alias{} = alias_ -> alias_candidate(alias_)
      nil -> concrete_candidate(model, capability)
    end
  end

  defp alias_candidate(alias_) do
    case Routing.candidates(alias_, %{}) do
      {:ok, [candidate | _]} -> {:ok, candidate}
      {:ok, []} -> {:error, :no_deployment}
      {:error, _reason} -> {:error, :no_deployment}
    end
  end

  defp concrete_candidate(model, capability) do
    case Config.list_deployments_by_model(model, capability) do
      [] -> {:error, {:model_not_found, model}}
      deployments -> {:ok, deployments |> Routing.deployment_candidates() |> hd()}
    end
  end

  defp target(%{deployment: deployment, provider: provider}, _model, intent) do
    uri = realtime_uri(provider.base_url, deployment.model_name, intent)

    %{
      ws_scheme: ws_scheme(uri.scheme),
      host: uri.host,
      port: uri.port,
      path: path_with_query(uri),
      headers: Transport.auth_headers(provider),
      deployment: deployment,
      provider: provider
    }
  end

  # Mirror the HTTP transport's base_url convention (base includes /v1), swapping
  # the scheme to ws(s) and appending the realtime endpoint + session params.
  defp realtime_uri(base_url, model_name, intent) do
    query = URI.encode_query(%{"model" => model_name, "intent" => intent})

    base_url
    |> String.trim_trailing("/")
    |> Kernel.<>("/realtime?" <> query)
    |> URI.parse()
  end

  defp ws_scheme("https"), do: :wss
  defp ws_scheme("http"), do: :ws
  defp ws_scheme("wss"), do: :wss
  defp ws_scheme("ws"), do: :ws

  defp path_with_query(%URI{path: path, query: nil}), do: path
  defp path_with_query(%URI{path: path, query: query}), do: path <> "?" <> query
end
