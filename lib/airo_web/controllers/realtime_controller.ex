defmodule AiroWeb.RealtimeController do
  @moduledoc """
  Realtime front door: `GET /v1/realtime?model=<alias|id>&intent=transcription`
  (WebSocket upgrade). Authenticated by `ClientKeyAuth`. Resolves the model +
  intent to an upstream WS target *before* upgrading — so resolution failures are
  clean HTTP errors — then upgrades into `AiroWeb.RealtimeProxy`, which relays to
  the provider. Up-front `x-gateway-*` headers ride on the 101 response.
  """
  use AiroWeb, :controller

  alias Airo.Realtime
  alias AiroWeb.{GatewayError, GatewayHeaders, RealtimeProxy}

  def connect(conn, params) do
    model = params["model"]
    intent = params["intent"] || "transcription"

    cond do
      model in [nil, ""] ->
        GatewayError.send_error(conn, :missing_model)

      true ->
        case Realtime.resolve(model, conn.assigns.client_key, intent) do
          {:ok, target} -> upgrade(conn, model, target)
          {:error, reason} -> GatewayError.send_error(conn, reason)
        end
    end
  end

  defp upgrade(conn, model, target) do
    conn
    |> GatewayHeaders.put(%{provider: target.provider, deployment: target.deployment}, [])
    |> WebSockAdapter.upgrade(RealtimeProxy, initial_state(conn, model, target), timeout: 120_000)
    |> halt()
  end

  defp initial_state(conn, model, target) do
    %{
      target: target,
      client_key: conn.assigns.client_key,
      model: model,
      started_at: System.monotonic_time(:millisecond),
      conn: nil,
      ref: nil,
      websocket: nil,
      status: :init,
      pending: [],
      upstream_status: nil,
      usage_recorded: false
    }
  end
end
