defmodule AiroWeb.RealtimeProxy do
  @moduledoc """
  A `WebSock` handler that reverse-proxies a realtime session: the consumer's
  server connects here (Bandit inbound), and Airo opens an outbound
  `Mint.WebSocket` to the resolved provider, relaying frames both ways
  (DESIGN-realtime-and-client.md §4).

  Transparent pass-through — text/binary/ping/pong/close frames are forwarded
  verbatim; Airo brokers the connection (credentials, network path), it does not
  translate the realtime protocol. Connect-time routing only; on a mid-session
  upstream failure the client session is closed.

  Lifecycle: the client WebSocket is already upgraded when `init/1` runs, so the
  outbound connection is opened there; client frames that arrive before the
  upstream handshake completes are buffered and flushed on open.
  """
  @behaviour WebSock

  require Logger

  alias Airo.Usage

  @impl true
  def init(state) do
    case connect(state.target) do
      {:ok, conn, ref} ->
        {:ok, %{state | conn: conn, ref: ref, status: :connecting, pending: []}}

      {:error, reason} ->
        Logger.warning("realtime: upstream connect failed: #{inspect(reason)}")
        record_usage(state, :error)
        {:push, [{:close, 1011, "upstream unavailable"}], %{state | status: :closed}}
    end
  end

  @impl true
  # Client → upstream.
  def handle_in({data, [opcode: opcode]}, %{status: :open} = state) do
    case send_upstream(state, {opcode, data}) do
      {:ok, state} -> {:ok, state}
      {:error, state, reason} -> close(state, reason)
    end
  end

  def handle_in({data, [opcode: opcode]}, %{status: :connecting} = state) do
    {:ok, %{state | pending: [{opcode, data} | state.pending]}}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  # Messages from the upstream Mint connection (TCP/SSL).
  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        process(responses, %{state | conn: conn}, [])

      {:error, conn, reason, _responses} ->
        Logger.warning("realtime: upstream stream error: #{inspect(reason)}")
        close(%{state | conn: conn}, reason)

      :unknown ->
        {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    if state[:conn], do: Mint.HTTP.close(state.conn)
    unless state[:usage_recorded], do: record_usage(state, :success)
    :ok
  end

  ## ── outbound connect / send ──────────────────────────────────────

  defp connect(target) do
    http_scheme = if target.ws_scheme == :wss, do: :https, else: :http

    with {:ok, conn} <-
           Mint.HTTP.connect(http_scheme, target.host, target.port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(target.ws_scheme, conn, target.path, target.headers) do
      {:ok, conn, ref}
    end
  end

  defp send_upstream(state, {opcode, data}) do
    with {:ok, websocket, frame} <- Mint.WebSocket.encode(state.websocket, {opcode, data}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, frame) do
      {:ok, %{state | websocket: websocket, conn: conn}}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}

      {:error, conn, reason} ->
        {:error, %{state | conn: conn}, reason}
    end
  end

  ## ── inbound response processing (upstream → client) ──────────────

  # Fold Mint responses, accumulating frames to push to the client.
  defp process([], state, pushes), do: {:push, Enum.reverse(pushes), state}

  defp process([{:status, ref, status} | rest], %{ref: ref} = state, pushes),
    do: process(rest, %{state | upstream_status: status}, pushes)

  defp process([{:headers, ref, headers} | rest], %{ref: ref} = state, pushes) do
    case Mint.WebSocket.new(state.conn, ref, state.upstream_status, headers) do
      {:ok, conn, websocket} ->
        state = flush_pending(%{state | conn: conn, websocket: websocket, status: :open})
        process(rest, state, pushes)

      {:error, conn, reason} ->
        Logger.warning("realtime: upstream upgrade rejected: #{inspect(reason)}")

        {:push, Enum.reverse([{:close, 1011, "upstream upgrade failed"} | pushes]),
         close_state(%{state | conn: conn})}
    end
  end

  defp process([{:data, ref, data} | rest], %{ref: ref, status: :open} = state, pushes) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        process(rest, %{state | websocket: websocket}, prepend_frames(frames, pushes))

      {:error, websocket, reason} ->
        Logger.warning("realtime: decode error: #{inspect(reason)}")

        {:push, Enum.reverse([{:close, 1011, "decode error"} | pushes]),
         close_state(%{state | websocket: websocket})}
    end
  end

  defp process([_other | rest], state, pushes), do: process(rest, state, pushes)

  # Map decoded upstream frames to client pushes (verbatim), newest-first into the
  # accumulator (reversed when emitted).
  defp prepend_frames(frames, pushes) do
    Enum.reduce(frames, pushes, fn
      {:text, data}, acc -> [{:text, data} | acc]
      {:binary, data}, acc -> [{:binary, data} | acc]
      {:ping, data}, acc -> [{:ping, data} | acc]
      {:pong, data}, acc -> [{:pong, data} | acc]
      {:close, code, reason}, acc -> [{:close, code || 1000, reason || ""} | acc]
      :close, acc -> [{:close, 1000, ""} | acc]
      _other, acc -> acc
    end)
  end

  defp flush_pending(%{pending: pending} = state) do
    state = %{state | pending: []}

    Enum.reduce(Enum.reverse(pending), state, fn frame, state ->
      case send_upstream(state, frame) do
        {:ok, state} -> state
        {:error, state, _reason} -> state
      end
    end)
  end

  ## ── close / usage ────────────────────────────────────────────────

  defp close(state, reason) do
    Logger.debug("realtime: closing session: #{inspect(reason)}")
    {:stop, :normal, 1011, close_state(state)}
  end

  defp close_state(state) do
    record_usage(state, outcome_for(state))
    %{state | status: :closed, usage_recorded: true}
  end

  defp outcome_for(%{status: :open}), do: :success
  defp outcome_for(_state), do: :error

  defp record_usage(%{usage_recorded: true}, _outcome), do: :ok

  defp record_usage(state, outcome) do
    Usage.record_async(%{
      client_key: state.client_key,
      served: %{deployment: state.target.deployment},
      alias_name: state.model,
      capability: state.target.deployment.capability,
      outcome: outcome,
      latency_ms: System.monotonic_time(:millisecond) - state.started_at
    })
  end
end
