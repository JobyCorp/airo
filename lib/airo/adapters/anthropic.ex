defmodule Airo.Adapters.Anthropic do
  @moduledoc """
  Adapter for Anthropic's Messages API, presented OpenAI-shaped (DESIGN §6).

  Accepts an OpenAI `/chat/completions` request, translates it to
  `POST /v1/messages` (`Airo.Adapters.Anthropic.Translate`), manages claude-code
  OAuth refresh and the Anthropic auth/beta headers
  (`Airo.Adapters.Anthropic.OAuth`), and normalizes the response — and the SSE
  stream — back to OpenAI deltas. Reasoning surfaces as `delta.reasoning_content`
  and tools as `delta.tool_calls`.

  Header configuration (with sane defaults):

      config :airo, Airo.Adapters.Anthropic,
        version: "2023-06-01",
        beta: "oauth-2025-04-20"
  """
  @behaviour Airo.Adapter

  alias Airo.Adapter.Context
  alias Airo.Adapters.Anthropic.{OAuth, Translate}
  alias Airo.Config.{Deployment, Provider, Secret}
  alias Airo.Transport

  @impl Airo.Adapter
  def chat(params, %Context{provider: provider} = ctx) when is_map(params) do
    with {:ok, headers} <- headers(provider) do
      body = Translate.request(params, model(ctx.deployment, params))

      case Transport.post(ctx, "/v1/messages", body, headers: headers) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          {:ok, Translate.response(response)}

        {:ok, %{status: status, body: response}} ->
          {:error, {:http_error, status, response}}

        {:error, reason} ->
          {:error, {:transport_error, reason}}
      end
    end
  end

  @impl Airo.Adapter
  def stream(params, %Context{provider: provider} = ctx, acc, reducer) when is_map(params) do
    case headers(provider) do
      {:ok, headers} ->
        body =
          params |> Translate.request(model(ctx.deployment, params)) |> Map.put("stream", true)

        # Each Anthropic SSE event becomes zero or more OpenAI delta chunks,
        # which we fold through the caller's reducer.
        translating = fn event, current ->
          event |> Translate.stream_event() |> Enum.reduce(current, reducer)
        end

        Transport.stream(ctx, "/v1/messages", body, acc, translating, headers: headers)

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  defp model(%Deployment{model_name: model}, _params) when is_binary(model), do: model
  defp model(_deployment, params), do: params["model"]

  # Anthropic auth differs from the OpenAI Bearer convention: api keys go in
  # `x-api-key`, OAuth access tokens (refreshed as needed) in `authorization`.
  defp headers(%Provider{auth_kind: :oauth} = provider) do
    with {:ok, token} <- OAuth.ensure_fresh(provider) do
      {:ok, [{"authorization", "Bearer " <> token}, version_header() | beta_header()]}
    end
  end

  defp headers(%Provider{auth_kind: :api_key, credential: %Secret{value: key}})
       when is_binary(key),
       do: {:ok, [{"x-api-key", key}, version_header()]}

  defp headers(%Provider{auth_kind: :none}), do: {:ok, [version_header()]}

  defp headers(_provider), do: {:error, :no_credential}

  defp version_header,
    do: {"anthropic-version", Keyword.get(config(), :version, Translate.anthropic_version())}

  defp beta_header do
    case Keyword.get(config(), :beta) do
      beta when is_binary(beta) -> [{"anthropic-beta", beta}]
      _ -> []
    end
  end

  defp config, do: Application.get_env(:airo, __MODULE__, [])
end
