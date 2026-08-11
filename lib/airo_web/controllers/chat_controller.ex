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
  alias AiroWeb.{GatewayError, GatewayTrace, GatewayUsage}

  def create(conn, params) do
    started = System.monotonic_time(:millisecond)
    capability = if streaming?(params), do: :stream, else: :chat

    case Gateway.resolve(params, conn.assigns.client_key, capability) do
      {:ok, plan} when capability == :stream -> stream_completion(conn, plan, started)
      {:ok, plan} -> chat_completion(conn, plan, started)
      {:error, reason} -> send_error(conn, reason, :chat, params["model"], started)
    end
  end

  defp streaming?(params), do: params["stream"] == true

  defp chat_completion(conn, plan, started) do
    case Gateway.run(plan) do
      {:ok, response, info} ->
        latency = System.monotonic_time(:millisecond) - started
        GatewayUsage.record(conn, plan, info, response: response, latency_ms: latency)

        conn
        |> put_gateway_headers(info.served,
          fallback_used: info.fallback_used,
          latency_ms: latency
        )
        |> json(response)

      {:error, reason} ->
        send_error(conn, reason, plan.usage_capability, plan.model, started)
    end
  end

  defp stream_completion(conn, plan, started) do
    # Up-front headers reflect the routing primary; the authoritative served
    # candidate (after any failover) lands in the trailing metadata event. The
    # response is not committed until the first delta is chunked, so a pre-byte
    # failover (or total failure) can still return a clean HTTP status.
    conn = put_gateway_headers(conn, hd(plan.attempts), [])

    case Gateway.run_stream(plan, conn, &sse_delta/2, &committed?/1) do
      {:ok, conn, info} ->
        latency = System.monotonic_time(:millisecond) - started

        GatewayUsage.record(conn, plan, info,
          latency_ms: latency,
          response: stream_response(conn)
        )

        meta =
          Gateway.transparency(info.served,
            fallback_used: info.fallback_used,
            latency_ms: latency
          )
          |> GatewayTrace.put_meta(GatewayTrace.conn_trace_id(conn))

        conn = ensure_chunked(conn)
        {:ok, conn} = sse_event(conn, "gateway.metadata", meta)
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        conn

      {:partial_error, reason, conn} ->
        # Output already began — finish with a terminal error event.
        GatewayUsage.record_error(conn, plan.usage_capability, reason,
          request_model: plan.model,
          latency_ms: System.monotonic_time(:millisecond) - started
        )

        {:ok, conn} = sse_event(conn, "gateway.error", error_meta(reason))
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        conn

      {:error, reason, _conn} ->
        # Every attempt failed before emitting anything; nothing is committed.
        send_error(conn, reason, plan.usage_capability, plan.model, started)
    end
  end

  defp committed?(conn), do: conn.state == :chunked

  # Reducer: lazily open the chunked response on the first delta, then write it
  # as an SSE `data:` line. Deferring `send_chunked` keeps pre-byte failover open.
  defp sse_delta(chunk, conn) do
    conn = conn |> ensure_chunked() |> note_stream_stats(chunk)
    {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(chunk) <> "\n\n")
    conn
  end

  # A stream leaves no response body to lift usage from afterwards, so lift it
  # in flight: merge each chunk's `usage` (an upstream may split prompt and
  # completion counts across chunks) and keep the last finish_reason seen.
  defp note_stream_stats(conn, chunk) do
    usage = Map.merge(conn.private[:airo_stream_usage] || %{}, chunk["usage"] || %{})
    finish = stream_finish(chunk) || conn.private[:airo_stream_finish]

    conn
    |> put_private(:airo_stream_usage, usage)
    |> put_private(:airo_stream_finish, finish)
  end

  defp stream_finish(%{"choices" => [%{"finish_reason" => reason} | _]}) when is_binary(reason),
    do: reason

  defp stream_finish(_chunk), do: nil

  # Reassemble the pieces into just enough OpenAI response shape for
  # `Airo.Usage.build_attrs/1` (usage + finish_reason). Nil when the stream
  # carried neither.
  defp stream_response(conn) do
    usage = conn.private[:airo_stream_usage]
    finish = conn.private[:airo_stream_finish]

    cond do
      is_map(usage) and map_size(usage) > 0 ->
        %{"usage" => usage, "choices" => [%{"finish_reason" => finish}]}

      is_binary(finish) ->
        %{"choices" => [%{"finish_reason" => finish}]}

      true ->
        nil
    end
  end

  defp ensure_chunked(%Plug.Conn{state: :chunked} = conn), do: conn

  defp ensure_chunked(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  defp sse_event(conn, event, payload) do
    chunk(conn, "event: " <> event <> "\ndata: " <> Jason.encode!(payload) <> "\n\n")
  end

  defp put_gateway_headers(conn, served, opts) do
    meta = Gateway.transparency(served, opts)

    conn
    |> put_resp_header("x-gateway-provider", meta["provider"])
    |> put_resp_header("x-gateway-model", meta["model"])
    |> put_resp_header("x-gateway-deployment", to_string(meta["deployment_id"]))
    |> put_resp_header("x-gateway-fallback", to_string(meta["fallback_used"]))
    |> maybe_trace_header(GatewayTrace.conn_trace_id(conn))
    |> maybe_latency_header(meta["latency_ms"])
  end

  defp maybe_trace_header(conn, nil), do: conn

  defp maybe_trace_header(conn, trace_id),
    do: put_resp_header(conn, "x-gateway-trace-id", trace_id)

  defp maybe_latency_header(conn, nil), do: conn

  defp maybe_latency_header(conn, ms),
    do: put_resp_header(conn, "x-gateway-latency-ms", to_string(ms))

  defp send_error(conn, reason, capability, model, started) do
    GatewayUsage.record_error(conn, capability, reason,
      request_model: model,
      latency_ms: System.monotonic_time(:millisecond) - started
    )

    GatewayError.send_error(conn, reason)
  end

  defp error_meta({:transport_error, _}), do: %{"error" => "upstream_unavailable"}

  defp error_meta({:http_error, status, _}),
    do: %{"error" => "upstream_error", "status" => status}

  defp error_meta(_), do: %{"error" => "stream_failed"}
end
