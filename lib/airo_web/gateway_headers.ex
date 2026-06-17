defmodule AiroWeb.GatewayHeaders do
  @moduledoc """
  Attaches `x-gateway-*` transparency headers (DESIGN §5.1) from a served
  attempt, shared across gateway controllers. `latency_ms` is omitted when nil
  (e.g. the up-front headers on a stream, where latency lands in the trailer).
  """
  import Plug.Conn, only: [put_resp_header: 3]

  alias Airo.Gateway
  alias AiroWeb.GatewayTrace

  @spec put(Plug.Conn.t(), Gateway.attempt(), keyword()) :: Plug.Conn.t()
  def put(conn, served, opts \\ []) do
    meta = Gateway.transparency(served, opts)

    conn
    |> put_resp_header("x-gateway-provider", meta["provider"])
    |> put_resp_header("x-gateway-model", meta["model"])
    |> put_resp_header("x-gateway-deployment", to_string(meta["deployment_id"]))
    |> put_resp_header("x-gateway-fallback", to_string(meta["fallback_used"]))
    |> put_trace(GatewayTrace.conn_trace_id(conn))
    |> maybe_latency(meta["latency_ms"])
  end

  defp put_trace(conn, nil), do: conn
  defp put_trace(conn, trace_id), do: put_resp_header(conn, "x-gateway-trace-id", trace_id)

  defp maybe_latency(conn, nil), do: conn
  defp maybe_latency(conn, ms), do: put_resp_header(conn, "x-gateway-latency-ms", to_string(ms))
end
