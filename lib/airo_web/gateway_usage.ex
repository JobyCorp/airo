defmodule AiroWeb.GatewayUsage do
  @moduledoc """
  Records a successful gateway call as a `UsageRecord` (off-path), shared across
  gateway controllers. The semantic capability comes from the alias (the config
  enum), not the adapter capability name.
  """
  alias Airo.Usage

  @spec record(Plug.Conn.t(), Airo.Gateway.plan(), Airo.Gateway.info(), keyword()) :: :ok
  def record(conn, plan, info, opts \\ []) do
    Usage.record_async(%{
      client_key: conn.assigns.client_key,
      served: info.served,
      alias_name: plan.alias.name,
      capability: plan.alias.capability,
      fallback_used: info.fallback_used,
      outcome: :success,
      response: opts[:response],
      latency_ms: opts[:latency_ms]
    })
  end
end
