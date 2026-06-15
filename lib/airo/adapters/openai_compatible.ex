defmodule Airo.Adapters.OpenAICompatible do
  @moduledoc """
  Adapter for genuinely OpenAI-compatible upstreams — vLLM, Ollama, LM Studio,
  OpenAI itself, and Speaches' audio endpoints (DESIGN §6). The request is
  already in canonical (OpenAI) shape, so this is near-passthrough: forward the
  body to the provider's endpoint and hand back the decoded response.

  Implements `chat/2` (non-streaming) and `stream/4`. Since these upstreams
  already emit OpenAI-shaped SSE deltas, streaming is near-passthrough — the
  Transport parses the SSE and we forward each chunk unchanged. The remaining
  capabilities land in later sprints.
  """
  @behaviour Airo.Adapter

  alias Airo.Adapter.Context
  alias Airo.Config.Deployment
  alias Airo.Transport

  @impl Airo.Adapter
  def chat(params, %Context{} = ctx) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> then(&Transport.post(ctx, "/chat/completions", &1))
    |> handle_response()
  end

  @impl Airo.Adapter
  def stream(params, %Context{} = ctx, acc, reducer) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> Map.put("stream", true)
    |> then(&Transport.stream(ctx, "/chat/completions", &1, acc, reducer))
  end

  # When routing has chosen a concrete deployment, the upstream model is the
  # deployment's model_name — override whatever logical alias the client sent.
  defp put_model(params, %Deployment{model_name: model}) when is_binary(model),
    do: Map.put(params, "model", model)

  defp put_model(params, _), do: params

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}), do: {:error, {:transport_error, reason}}
end
