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

        {:stop, :normal, {1011, "upstream unavailable"}, close_state(%{state | status: :error})}
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

  # Fold Mint responses into the frames to push to the client, tracking a terminal
  # close. WebSock has no pushable close frame — a close is a `{:stop, …}` return
  # with a `close_detail` (`code | {code, reason}`), so we flush pending pushes and
  # stop rather than pushing a `{:close, …}` (which crashes Bandit's deflate).
  defp process(responses, state, pushes), do: process(responses, state, pushes, nil)

  defp process([], state, pushes, nil), do: {:push, Enum.reverse(pushes), state}

  defp process([], state, pushes, close),
    do: {:stop, :normal, close, Enum.reverse(pushes), close_state(state)}

  defp process([{:status, ref, status} | rest], %{ref: ref} = state, pushes, close),
    do: process(rest, %{state | upstream_status: status}, pushes, close)

  defp process([{:headers, ref, headers} | rest], %{ref: ref} = state, pushes, close) do
    case Mint.WebSocket.new(state.conn, ref, state.upstream_status, headers) do
      {:ok, conn, websocket} ->
        state = flush_pending(%{state | conn: conn, websocket: websocket, status: :open})
        process(rest, state, pushes, close)

      {:error, conn, reason} ->
        Logger.warning("realtime: upstream upgrade rejected: #{inspect(reason)}")

        {:stop, :normal, {1011, "upstream upgrade failed"}, Enum.reverse(pushes),
         close_state(%{state | conn: conn, status: :error})}
    end
  end

  defp process([{:data, ref, data} | rest], %{ref: ref, status: :open} = state, pushes, close) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        {pushes, close} = collect_frames(frames, pushes, close)
        process(rest, %{state | websocket: websocket}, pushes, close)

      {:error, websocket, reason} ->
        Logger.warning("realtime: decode error: #{inspect(reason)}")

        {:stop, :normal, {1011, "decode error"}, Enum.reverse(pushes),
         close_state(%{state | websocket: websocket, status: :error})}
    end
  end

  defp process([_other | rest], state, pushes, close), do: process(rest, state, pushes, close)

  # Map decoded upstream frames to client pushes (verbatim), newest-first into the
  # accumulator; an upstream close becomes the terminal `close_detail` (once set,
  # later frames are dropped — the session is ending).
  defp collect_frames(frames, pushes, close) do
    Enum.reduce(frames, {pushes, close}, fn
      _frame, {pushes, {_code, _reason} = close} -> {pushes, close}
      {:text, data}, {pushes, nil} -> {[{:text, data} | pushes], nil}
      {:binary, data}, {pushes, nil} -> {[{:binary, data} | pushes], nil}
      {:ping, data}, {pushes, nil} -> {[{:ping, data} | pushes], nil}
      {:pong, data}, {pushes, nil} -> {[{:pong, data} | pushes], nil}
      {:close, code, reason}, {pushes, nil} -> {pushes, {code || 1000, reason || ""}}
      :close, {pushes, nil} -> {pushes, {1000, ""}}
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
    latency = System.monotonic_time(:millisecond) - state.started_at

    Logger.info("gateway.realtime.closed",
      gateway_trace_id: state[:trace_id],
      client_key_id: state.client_key && state.client_key.id,
      client_key_name: state.client_key && state.client_key.name,
      request_model: state.model,
      capability: state.target.capability,
      provider: state.target.provider.name,
      deployment_id: state.target.deployment.id,
      model: state.target.deployment.model_name,
      outcome: outcome,
      latency_ms: latency
    )

    Usage.record_async(%{
      client_key: state.client_key,
      trace_id: state[:trace_id],
      served: %{deployment: state.target.deployment},
      alias_name: state.model,
      capability: state.target.capability,
      outcome: outcome,
      latency_ms: latency
    })
  rescue
    # Usage accounting is best-effort — a recording failure must never tear down
    # the relay (in async mode the Task isolates this; this guards the sync path).
    error ->
      Logger.warning("realtime: usage record failed: #{inspect(error)}")
      :ok
  end
end
