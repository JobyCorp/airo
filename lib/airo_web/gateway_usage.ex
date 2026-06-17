defmodule AiroWeb.GatewayUsage do
  @moduledoc """
  Records a successful gateway call as a `UsageRecord` (off-path), shared across
  gateway controllers. The semantic capability comes from the alias (the config
  enum), not the adapter capability name.
  """
  require Logger

  alias Airo.Usage
  alias AiroWeb.{GatewayError, GatewayTrace}

  @spec record(Plug.Conn.t(), Airo.Gateway.plan(), Airo.Gateway.info(), keyword()) :: :ok
  def record(conn, plan, info, opts \\ []) do
    trace_id = GatewayTrace.conn_trace_id(conn)

    Logger.info("gateway.request.completed",
      gateway_trace_id: trace_id,
      client_key_id: conn.assigns.client_key.id,
      client_key_name: conn.assigns.client_key.name,
      request_model: plan.model,
      capability: plan.usage_capability,
      provider: info.served.provider.name,
      deployment_id: info.served.deployment.id,
      model: info.served.deployment.model_name,
      fallback_used: info.fallback_used,
      latency_ms: opts[:latency_ms]
    )

    Usage.record_async(%{
      client_key: conn.assigns.client_key,
      trace_id: trace_id,
      served: info.served,
      alias_name: plan.model,
      capability: plan.usage_capability,
      fallback_used: info.fallback_used,
      outcome: :success,
      response: opts[:response],
      latency_ms: opts[:latency_ms]
    })
  end

  @spec record_error(Plug.Conn.t(), atom() | nil, term(), keyword()) :: :ok
  def record_error(conn, capability, reason, opts \\ []) do
    {status, _body} = GatewayError.response(reason)
    trace_id = GatewayTrace.conn_trace_id(conn)
    client_key = conn.assigns[:client_key]

    Logger.warning("gateway.request.failed",
      gateway_trace_id: trace_id,
      client_key_id: client_key && client_key.id,
      client_key_name: client_key && client_key.name,
      request_model: opts[:request_model],
      capability: capability,
      error_code: GatewayError.code(reason),
      http_status: status,
      upstream_status: GatewayError.upstream_status(reason),
      latency_ms: opts[:latency_ms]
    )

    Usage.record_async(%{
      client_key: client_key,
      trace_id: trace_id,
      request_model: opts[:request_model],
      alias_name: opts[:request_model],
      capability: capability,
      latency_ms: opts[:latency_ms],
      outcome: :error,
      error_code: GatewayError.code(reason),
      http_status: status,
      upstream_status: GatewayError.upstream_status(reason)
    })
  end

  @doc "Best-effort capability attribution from an incoming gateway path."
  def capability_for_path(path) do
    cond do
      String.ends_with?(path, "/chat/completions") -> :chat
      String.ends_with?(path, "/embeddings") -> :embeddings
      String.ends_with?(path, "/rerank") -> :rerank
      String.ends_with?(path, "/classify") -> :classify
      String.ends_with?(path, "/audio/speech") -> :speech
      String.ends_with?(path, "/audio/transcriptions") -> :transcription
      String.ends_with?(path, "/realtime") -> :transcription
      true -> nil
    end
  end
end
