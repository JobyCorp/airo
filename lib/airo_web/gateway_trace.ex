defmodule AiroWeb.GatewayTrace do
  @moduledoc """
  Gateway trace identity shared by HTTP, SSE, realtime, logs, and usage rows.

  Airo accepts an inbound `x-gateway-trace-id` or `x-request-id` when present.
  Otherwise it mints a compact id. The value is intentionally separate from
  Plug's request id so downstream clients can depend on a gateway-specific
  header while still benefiting from Plug/Phoenix request logging.
  """
  import Plug.Conn

  require Logger

  @header "x-gateway-trace-id"

  @doc "Plug entrypoint. Assigns and emits the gateway trace id."
  def init(opts), do: opts

  def call(conn, _opts) do
    trace_id = request_trace_id(conn) || new_id()

    Logger.metadata(gateway_trace_id: trace_id)

    conn
    |> assign(:gateway_trace_id, trace_id)
    |> put_resp_header(@header, trace_id)
  end

  @doc "Fetch the trace id assigned to a conn, if present."
  def conn_trace_id(%Plug.Conn{assigns: assigns}), do: assigns[:gateway_trace_id]

  @doc "Put the trace id into a metadata map when available."
  def put_meta(map, nil), do: map
  def put_meta(map, trace_id), do: Map.put(map, "trace_id", trace_id)

  @doc "Mint a compact URL/log-safe trace id."
  def new_id do
    "gt_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  defp request_trace_id(conn) do
    conn
    |> header("x-gateway-trace-id")
    |> fallback(header(conn, "x-request-id"))
    |> normalize()
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp fallback(nil, value), do: value
  defp fallback("", value), do: value
  defp fallback(value, _fallback), do: value

  defp normalize(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: String.slice(value, 0, 128)
  end

  defp normalize(_), do: nil
end
