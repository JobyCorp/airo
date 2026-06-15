defmodule AiroWeb.RealtimeProxyTest do
  # Drives the WebSock callbacks directly against a real echo upstream. init/1
  # opens the Mint socket in *this* process, so its messages arrive here and we
  # feed them to handle_info/2 — exercising the full relay without an HTTP server.
  use ExUnit.Case, async: false

  alias Airo.Config.{Deployment, Provider}
  alias AiroWeb.RealtimeProxy

  @port 4123
  @reject_port 4124

  setup do
    start_supervised!({Airo.Test.EchoServer, port: @port})
    :ok
  end

  defp initial_state do
    target = %{
      ws_scheme: :ws,
      host: "localhost",
      port: @port,
      path: "/realtime?model=echo&intent=transcription",
      headers: [],
      deployment: %Deployment{model_name: "echo", capability: :transcription},
      provider: %Provider{name: "echo"}
    }

    %{
      target: target,
      client_key: nil,
      model: "echo",
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

  # Feed upstream Mint messages into handle_info until the session opens.
  defp pump_until_open(%{status: :open} = state), do: state

  defp pump_until_open(state) do
    receive do
      message ->
        case RealtimeProxy.handle_info(message, state) do
          {:ok, state} -> pump_until_open(state)
          {:push, _pushes, state} -> pump_until_open(state)
        end
    after
      5_000 -> flunk("timed out waiting for upstream to open")
    end
  end

  # Feed upstream Mint messages until the handler returns a `:stop`.
  defp pump_until_stop(state) do
    receive do
      message ->
        case RealtimeProxy.handle_info(message, state) do
          {:ok, state} -> pump_until_stop(state)
          {:push, _pushes, state} -> pump_until_stop(state)
          {:stop, _reason, _detail, _state} = stop -> stop
          {:stop, _reason, _detail, _pushes, _state} = stop -> stop
        end
    after
      5_000 -> flunk("timed out waiting for the proxy to stop")
    end
  end

  # Receive one upstream message and return the handler's pushes.
  defp recv_pushes(state) do
    receive do
      message ->
        case RealtimeProxy.handle_info(message, state) do
          {:push, pushes, state} -> {pushes, state}
          {:ok, state} -> recv_pushes(state)
        end
    after
      5_000 -> flunk("timed out waiting for an upstream frame")
    end
  end

  test "relays a text frame to the upstream and the echo back to the client" do
    assert {:ok, state} = RealtimeProxy.init(initial_state())
    assert state.status == :connecting

    state = pump_until_open(state)
    assert state.status == :open

    assert {:ok, state} = RealtimeProxy.handle_in({"hello realtime", [opcode: :text]}, state)

    {pushes, _state} = recv_pushes(state)
    assert {:text, "hello realtime"} in pushes
  end

  test "buffers client frames sent before the upstream is open, then flushes them" do
    assert {:ok, state} = RealtimeProxy.init(initial_state())

    # Send while still connecting → buffered.
    assert {:ok, state} = RealtimeProxy.handle_in({"early", [opcode: :text]}, state)
    assert state.status == :connecting
    assert state.pending != []

    # On open, pending flushes upstream; the echo comes back.
    state = pump_until_open(state)
    {pushes, _state} = recv_pushes(state)
    assert {:text, "early"} in pushes
  end

  test "stops with a close detail (no Bandit deflate crash) when the upstream rejects the upgrade" do
    start_supervised!({Airo.Test.RejectServer, port: @reject_port})
    state = put_in(initial_state(), [:target, :port], @reject_port)

    assert {:ok, state} = RealtimeProxy.init(state)

    # WebSock close must be a `{:stop, …}` with a close_detail — never a pushed
    # `{:close, …}` frame (which has no opcode and crashes Bandit's deflate).
    assert {:stop, :normal, {1011, _reason}, _pushes, _state} = pump_until_stop(state)
  end
end
