defmodule AiroWeb.EmbeddingsController do
  @moduledoc """
  OpenAI-compatible embeddings: `POST /v1/embeddings` (DESIGN §5). Resolves the
  `model` alias to an embeddings deployment via `Airo.Gateway`, dispatches the
  `:embed` capability, and returns the upstream OpenAI-shaped response with
  `x-gateway-*` transparency headers.
  """
  use AiroWeb, :controller

  alias Airo.Gateway
  alias AiroWeb.GatewayError

  def create(conn, params) do
    started = System.monotonic_time(:millisecond)

    with {:ok, plan} <- Gateway.resolve(params, conn.assigns.client_key, :embed),
         {:ok, response, info} <- Gateway.run(plan) do
      latency = System.monotonic_time(:millisecond) - started

      conn
      |> put_gateway_headers(info.served, fallback_used: info.fallback_used, latency_ms: latency)
      |> json(response)
    else
      {:error, reason} -> GatewayError.send_error(conn, reason)
    end
  end

  defp put_gateway_headers(conn, served, opts) do
    meta = Gateway.transparency(served, opts)

    conn
    |> put_resp_header("x-gateway-provider", meta["provider"])
    |> put_resp_header("x-gateway-model", meta["model"])
    |> put_resp_header("x-gateway-deployment", to_string(meta["deployment_id"]))
    |> put_resp_header("x-gateway-fallback", to_string(meta["fallback_used"]))
    |> put_resp_header("x-gateway-latency-ms", to_string(meta["latency_ms"]))
  end
end
