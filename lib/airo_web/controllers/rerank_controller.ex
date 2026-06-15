defmodule AiroWeb.RerankController do
  @moduledoc """
  Rerank: `POST /v1/rerank` (Jina/Cohere shape; OpenAI defines none — DESIGN §5).
  Resolves the `model` alias to a rerank deployment via `Airo.Gateway`,
  dispatches the `:rerank` capability, and returns the upstream response.
  """
  use AiroWeb, :controller

  alias Airo.Gateway
  alias AiroWeb.{GatewayError, GatewayHeaders}

  def create(conn, params) do
    started = System.monotonic_time(:millisecond)

    with {:ok, plan} <- Gateway.resolve(params, conn.assigns.client_key, :rerank),
         {:ok, response, info} <- Gateway.run(plan) do
      latency = System.monotonic_time(:millisecond) - started

      conn
      |> GatewayHeaders.put(info.served, fallback_used: info.fallback_used, latency_ms: latency)
      |> json(response)
    else
      {:error, reason} -> GatewayError.send_error(conn, reason)
    end
  end
end
