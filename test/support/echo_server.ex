defmodule Airo.Test.EchoWS do
  @moduledoc false
  # A trivial WebSocket echo handler — used as a stand-in realtime upstream so the
  # RealtimeProxy relay can be exercised against a real socket.
  @behaviour WebSock

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_in({data, [opcode: opcode]}, state), do: {:push, {opcode, data}, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end

defmodule Airo.Test.EchoServer do
  @moduledoc false
  # A Bandit server that upgrades any request to the echo WebSocket handler.
  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)
    Bandit.child_spec(plug: __MODULE__, scheme: :http, port: port, startup_log: false)
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> WebSockAdapter.upgrade(Airo.Test.EchoWS, %{}, [])
    |> Plug.Conn.halt()
  end
end

defmodule Airo.Test.RejectServer do
  @moduledoc false
  # A Bandit server that answers a plain HTTP 404 instead of upgrading — a stand-in
  # for an upstream that rejects the WebSocket upgrade (e.g. model_not_found).
  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)
    Bandit.child_spec(plug: __MODULE__, scheme: :http, port: port, startup_log: false)
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    Plug.Conn.send_resp(conn, 404, ~s({"error":{"code":"model_not_found"}}))
  end
end
