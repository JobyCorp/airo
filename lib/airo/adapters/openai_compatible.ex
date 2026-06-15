defmodule Airo.Adapters.OpenAICompatible do
  @moduledoc """
  Adapter for genuinely OpenAI-compatible upstreams — vLLM, Ollama, LM Studio,
  OpenAI itself, and Speaches' audio endpoints (DESIGN §6). The request is
  already in canonical (OpenAI) shape, so this is near-passthrough: forward the
  body to the provider's endpoint and hand back the decoded response.

  S1 implements `chat/2` (non-streaming) only. Streaming (`stream/3`) and the
  other capabilities land in later sprints.
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
