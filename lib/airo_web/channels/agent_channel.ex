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

  alias Airo.Agents.{Ingest, Lifecycle}
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
    host_id = socket.assigns.host_id

    {:ok, _ref} = Presence.track(socket, host_id, %{online_at: System.system_time(:second)})

    # The register that carries this connection's identity follows the join by a
    # beat, so the event is stamped with what the row *held* — the first register
    # then records a `version_changed`/`control_url_changed` if it differs (S25).
    Lifecycle.transition(host_id, :connected, meta: identity(host_id))

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
  def terminate(reason, socket) do
    host_id = socket.assigns.host_id

    Lifecycle.transition(host_id, :disconnected,
      reason: "agent_disconnected",
      meta: %{exit: inspect(reason)}
    )

    Ingest.host_down(host_id)
    :ok
  end

  defp identity(host_id) do
    case Airo.Config.get_agent_by_host_id(host_id) do
      %{version: version, control_url: url} -> %{version: version, control_url: url}
      nil -> %{}
    end
  end
end
