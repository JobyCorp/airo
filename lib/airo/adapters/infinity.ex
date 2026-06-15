defmodule Airo.Adapters.Infinity do
  @moduledoc """
  Adapter for [Infinity](https://github.com/michaelfeil/infinity) — an
  embeddings + rerank server (DESIGN §6). Embeddings are OpenAI-compatible
  (`/embeddings`); rerank uses the de-facto Jina/Cohere `/rerank` shape, which
  Airo exposes at `/v1/rerank`. Both are near-passthrough.
  """
  @behaviour Airo.Adapter

  alias Airo.Adapter.Context
  alias Airo.Config.Deployment
  alias Airo.Transport

  @impl Airo.Adapter
  def embed(params, %Context{} = ctx) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> then(&Transport.post(ctx, "/embeddings", &1))
    |> handle_response()
  end

  @impl Airo.Adapter
  def rerank(params, %Context{} = ctx) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> then(&Transport.post(ctx, "/rerank", &1))
    |> handle_response()
  end

  defp put_model(params, %Deployment{model_name: model}) when is_binary(model),
    do: Map.put(params, "model", model)

  defp put_model(params, _), do: params

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, {:transport_error, reason}}
end
