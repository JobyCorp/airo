defmodule AiroWeb.AudioController do
  @moduledoc """
  Audio endpoints fronting Speaches (DESIGN §5):

    - `POST /v1/audio/speech` — JSON in, binary audio out (`:speech`).
    - `POST /v1/audio/transcriptions` — multipart upload in, JSON out
      (`:transcribe`).

  Both resolve the `model` alias via `Airo.Gateway` and dispatch the capability.
  """
  use AiroWeb, :controller

  alias Airo.Gateway
  alias AiroWeb.{GatewayError, GatewayHeaders, GatewayUsage}

  def speech(conn, params) do
    started = System.monotonic_time(:millisecond)

    with {:ok, plan} <- Gateway.resolve(params, conn.assigns.client_key, :speech),
         {:ok, {:audio, content_type, data}, info} <- Gateway.run(plan) do
      latency = System.monotonic_time(:millisecond) - started
      GatewayUsage.record(conn, plan, info, latency_ms: latency)

      conn
      |> GatewayHeaders.put(info.served, fallback_used: info.fallback_used, latency_ms: latency)
      |> put_resp_content_type(content_type, nil)
      |> send_resp(200, data)
    else
      {:error, reason} ->
        GatewayUsage.record_error(conn, :speech, reason,
          request_model: params["model"],
          latency_ms: System.monotonic_time(:millisecond) - started
        )

        GatewayError.send_error(conn, reason)
    end
  end

  def transcriptions(conn, params) do
    started = System.monotonic_time(:millisecond)

    with {:ok, plan} <- Gateway.resolve(params, conn.assigns.client_key, :transcribe),
         {:ok, response, info} <- Gateway.run(plan) do
      latency = System.monotonic_time(:millisecond) - started
      GatewayUsage.record(conn, plan, info, response: response, latency_ms: latency)

      conn
      |> GatewayHeaders.put(info.served, fallback_used: info.fallback_used, latency_ms: latency)
      |> json(response)
    else
      {:error, reason} ->
        GatewayUsage.record_error(conn, :transcription, reason,
          request_model: params["model"],
          latency_ms: System.monotonic_time(:millisecond) - started
        )

        GatewayError.send_error(conn, reason)
    end
  end
end
