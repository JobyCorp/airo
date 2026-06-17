defmodule AiroWeb.RerankController do
  @moduledoc """
  Rerank: `POST /v1/rerank` (Jina/Cohere shape; OpenAI defines none — DESIGN §5).
  Resolves the `model` alias to a rerank deployment via `Airo.Gateway`,
  dispatches the `:rerank` capability, and returns the upstream response.
  """
  use AiroWeb, :controller

  alias Airo.Gateway
  alias AiroWeb.{GatewayError, GatewayHeaders, GatewayUsage}

  def create(conn, params) do
    started = System.monotonic_time(:millisecond)

    with {:ok, plan} <- Gateway.resolve(params, conn.assigns.client_key, :rerank),
         {:ok, response, info} <- Gateway.run(plan) do
      latency = System.monotonic_time(:millisecond) - started
      GatewayUsage.record(conn, plan, info, response: response, latency_ms: latency)

      conn
      |> GatewayHeaders.put(info.served, fallback_used: info.fallback_used, latency_ms: latency)
      |> json(response)
    else
      {:error, reason} ->
        GatewayUsage.record_error(conn, :rerank, reason,
          request_model: params["model"],
          latency_ms: System.monotonic_time(:millisecond) - started
        )

        GatewayError.send_error(conn, reason)
    end
  end
end
