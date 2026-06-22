defmodule AiroWeb.AgentChannel do
  @moduledoc """
  One channel per serving host (`agent:<host_id>`). The agent pushes lifecycle
  state; Airo never polls (decision #3).

      "snapshot" — full running set, on join and every rejoin (self-heal/reconcile)
      "event"    — a single AiroAgent.Fleet.Event (lifecycle transition)

  The only server→agent message is `"resync"` (ask for a fresh snapshot). Control
  (load/unload) stays on the agent's HTTP API — not this channel.

  `terminate/2` marks the host's deployments down: when the socket drops (host
  death, agent restart), the channel process dies and Airo reacts immediately. A
  transient blip is benign — the rejoin snapshot marks everything back up.
  """
  use Phoenix.Channel

  alias Airo.Agents.Ingest
  alias AiroWeb.Presence

  @impl true
  def join("agent:" <> host_id, _params, socket) do
    if host_id == socket.assigns.host_id do
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, %{reason: "host_id mismatch"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _ref} =
      Presence.track(socket, socket.assigns.host_id, %{online_at: System.system_time(:second)})

    {:noreply, socket}
  end

  @impl true
  def handle_in("snapshot", payload, socket) do
    Ingest.snapshot(socket.assigns.host_id, payload)
    {:noreply, socket}
  end

  def handle_in("event", payload, socket) do
    Ingest.event(socket.assigns.host_id, payload)
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    Ingest.host_down(socket.assigns.host_id)
    :ok
  end
end
