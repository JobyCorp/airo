defmodule AiroWeb.ChatController do
  @moduledoc """
  OpenAI-compatible chat front door: `POST /v1/chat/completions` (DESIGN §5).

  Authentication is handled upstream by `AiroWeb.Plugs.ClientKeyAuth`. We resolve
  the request to a dispatch plan via `Airo.Gateway`, attach `x-gateway-*`
  transparency headers, then either return a JSON completion or stream
  Server-Sent Events. For streams the per-request latency lands in a trailing
  `gateway.metadata` SSE event (headers are already flushed by then), followed by
  the OpenAI `[DONE]` sentinel.
  """
  use AiroWeb, :controller

  alias Airo.Gateway
  alias AiroWeb.OpenAIError

  def create(conn, params) do
    capability = if streaming?(params), do: :stream, else: :chat

    case Gateway.resolve(params, conn.assigns.client_key, capability) do
      {:ok, plan} when capability == :stream -> stream_completion(conn, plan)
      {:ok, plan} -> chat_completion(conn, plan)
      {:error, reason} -> send_error(conn, reason)
    end
  end

  defp streaming?(params), do: params["stream"] == true

  defp chat_completion(conn, plan) do
    started = System.monotonic_time(:millisecond)

    case Gateway.run(plan) do
      {:ok, response} ->
        latency = System.monotonic_time(:millisecond) - started

        conn
        |> put_gateway_headers(plan, latency)
        |> json(response)

      {:error, reason} ->
        send_error(conn, reason)
    end
  end

  defp stream_completion(conn, plan) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_gateway_headers(plan, nil)
      |> send_chunked(200)

    started = System.monotonic_time(:millisecond)

    case Gateway.run_stream(plan, conn, &sse_delta/2) do
      {:ok, conn} ->
        latency = System.monotonic_time(:millisecond) - started
        meta = Gateway.transparency(plan, latency_ms: latency)

        {:ok, conn} = sse_event(conn, "gateway.metadata", meta)
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        conn

      {:error, reason} ->
        # Headers are already sent; surface the failure as a terminal SSE event.
        {:ok, conn} = sse_event(conn, "gateway.error", error_meta(reason))
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        conn
    end
  end

  # Reducer: write one upstream delta chunk as an SSE `data:` line.
  defp sse_delta(chunk, conn) do
    {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(chunk) <> "\n\n")
    conn
  end

  defp sse_event(conn, event, payload) do
    chunk(conn, "event: " <> event <> "\ndata: " <> Jason.encode!(payload) <> "\n\n")
  end

  defp put_gateway_headers(conn, plan, latency_ms) do
    meta = Gateway.transparency(plan, latency_ms: latency_ms)

    conn
    |> put_resp_header("x-gateway-provider", meta["provider"])
    |> put_resp_header("x-gateway-model", meta["model"])
    |> put_resp_header("x-gateway-deployment", to_string(meta["deployment_id"]))
    |> put_resp_header("x-gateway-fallback", to_string(meta["fallback_used"]))
    |> maybe_latency_header(latency_ms)
  end

  defp maybe_latency_header(conn, nil), do: conn

  defp maybe_latency_header(conn, ms),
    do: put_resp_header(conn, "x-gateway-latency-ms", to_string(ms))

  defp error_meta({:transport_error, _}), do: %{"error" => "upstream_unavailable"}

  defp error_meta({:http_error, status, _}),
    do: %{"error" => "upstream_error", "status" => status}

  defp error_meta(_), do: %{"error" => "stream_failed"}

  defp send_error(conn, :missing_model) do
    error(
      conn,
      400,
      "You must provide a `model` parameter.",
      "invalid_request_error",
      "missing_model"
    )
  end

  defp send_error(conn, {:model_not_found, model}) do
    error(
      conn,
      404,
      "The model `#{model}` does not exist or you do not have access to it.",
      "invalid_request_error",
      "model_not_found"
    )
  end

  defp send_error(conn, {:forbidden, model}) do
    error(
      conn,
      403,
      "Your client key is not authorized for model `#{model}`.",
      "invalid_request_error",
      "model_not_authorized"
    )
  end

  defp send_error(conn, :no_deployment) do
    error(
      conn,
      503,
      "No healthy deployment is available for this model.",
      "api_error",
      "no_deployment_available"
    )
  end

  defp send_error(conn, {:no_adapter, type}) do
    error(
      conn,
      502,
      "No adapter is configured for provider type `#{type}`.",
      "api_error",
      "no_adapter"
    )
  end

  defp send_error(conn, {:unsupported_capability, capability}) do
    error(
      conn,
      502,
      "The selected provider does not support `#{capability}`.",
      "api_error",
      "unsupported_capability"
    )
  end

  # Upstream returned a non-2xx. If it already spoke an OpenAI error envelope,
  # pass it through verbatim under the upstream status; otherwise wrap it.
  defp send_error(conn, {:http_error, status, %{"error" => _} = body}) do
    send_json(conn, status, body)
  end

  defp send_error(conn, {:http_error, status, _body}) do
    error(conn, status, "The upstream provider returned an error.", "api_error", "upstream_error")
  end

  defp send_error(conn, {:transport_error, _reason}) do
    error(
      conn,
      502,
      "Failed to reach the upstream provider.",
      "api_error",
      "upstream_unavailable"
    )
  end

  defp error(conn, status, message, type, code) do
    send_json(conn, status, OpenAIError.body(message, type, code))
  end

  defp send_json(conn, status, body) do
    conn
    |> put_status(status)
    |> json(body)
  end
end
