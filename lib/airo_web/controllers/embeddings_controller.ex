defmodule AiroWeb.EmbeddingsController do
  @moduledoc """
  OpenAI-compatible embeddings: `POST /v1/embeddings` (DESIGN §5). Resolves the
  `model` alias to an embeddings deployment via `Airo.Gateway`, dispatches the
  `:embed` capability, and returns the upstream OpenAI-shaped response with
  `x-gateway-*` transparency headers.
  """
  use AiroWeb, :controller

  alias Airo.Gateway
  alias AiroWeb.{GatewayError, GatewayHeaders}

  def create(conn, params) do
    started = System.monotonic_time(:millisecond)

    with {:ok, plan} <- Gateway.resolve(params, conn.assigns.client_key, :embed),
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
