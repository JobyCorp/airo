defmodule AiroWeb.AgentChannel do
  @moduledoc """
  One channel per serving host (`agent:<host_id>`). The agent pushes state; Airo
  never polls (Model 2).

      "register" — agent identity + its serving slots, on join and every rejoin.
                   Upserts the Agent and its managed slot-Providers, and seeds
                   per-slot health (self-heal / reconcile).
      "slot"     — a single slot transition (a model loaded/swapped/down).

  Control (load/unload/swap) stays on the agent's HTTP control API — not this
  channel.

  `terminate/2` marks the host's deployments down: when the socket drops (host
  death, agent restart), the channel process dies and Airo reacts immediately. A
  transient blip is benign — the rejoin `register` marks everything back up.
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
  def handle_in("register", payload, socket) do
    Ingest.register(socket.assigns.host_id, payload)
    {:noreply, socket}
  end

  def handle_in("slot", payload, socket) do
    Ingest.slot(socket.assigns.host_id, payload)
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    Ingest.host_down(socket.assigns.host_id)
    :ok
  end
end
