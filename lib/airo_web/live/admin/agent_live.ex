defmodule AiroWeb.Admin.AgentLive do
  @moduledoc """
  Read-only view of registered host-side control agents (Model 2 — see
  `airo_agent/DESIGN.md` §"Airo-side shape"). One agent per serving host: it
  manages the engine slots (Providers) on that host, pushes GPU telemetry and
  per-slot health over its channel, and exposes a control API at `control_url`.

  Airo never polls the agent — registration and health arrive by channel push.
  This view is the consumer: which hosts are online (Presence), their GPU/VRAM
  posture, and the slots they manage with the model currently resident in each.
  """
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Health
  alias Airo.Repo
  alias AiroWeb.CompositeComponents
  alias AiroWeb.Presence

  # GPU telemetry and slot health are DB state written by the agent's channel
  # pushes (`Agents.Ingest`); a light timer re-reads them without a manual reload.
  # Online/offline is NOT on this timer — it's a Presence subscription (below).
  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(page_title: "Agents", detail: nil, subscribed: MapSet.new())
     |> assign_agents()
     |> subscribe_presence()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    socket =
      case socket.assigns.detail do
        %{agent: %{id: id}} -> assign(socket, detail: detail(id))
        _ -> socket
      end

    # Re-list to pick up newly-registered agents, and subscribe to any we don't
    # yet watch. Presence itself stays event-driven.
    {:noreply, socket |> assign_agents() |> subscribe_presence()}
  end

  # A host's Presence changed (connect/disconnect) — react immediately rather
  # than waiting for the next tick. Presence is a subscription, not a poll.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "agent:" <> host_id},
        socket
      ) do
    online = online?(host_id)

    socket =
      socket
      |> update(:online, &Map.put(&1, host_id, online))
      |> update_detail_online(host_id, online)

    {:noreply, socket}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(detail: nil, page_title: "Agents")
    |> assign_agents()
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    detail = detail(id)
    assign(socket, detail: detail, page_title: detail.agent.host_id)
  end

  defp assign_agents(socket) do
    agents = list()
    assign(socket, agents: agents, online: online_map(agents))
  end

  # Subscribe to the Presence topic of every agent we aren't already watching, so
  # connect/disconnect diffs arrive as messages. Idempotent: `subscribed` tracks
  # which host topics we hold, so re-listing never double-subscribes.
  defp subscribe_presence(%{assigns: %{agents: agents, subscribed: subscribed}} = socket) do
    if connected?(socket) do
      subscribed =
        Enum.reduce(agents, subscribed, fn agent, acc ->
          if MapSet.member?(acc, agent.host_id) do
            acc
          else
            Phoenix.PubSub.subscribe(Airo.PubSub, "agent:#{agent.host_id}")
            MapSet.put(acc, agent.host_id)
          end
        end)

      assign(socket, subscribed: subscribed)
    else
      socket
    end
  end

  defp update_detail_online(
         %{assigns: %{detail: %{agent: %{host_id: host_id}} = detail}} = socket,
         host_id,
         online
       ),
       do: assign(socket, detail: %{detail | online: online})

  defp update_detail_online(socket, _host_id, _online), do: socket

  defp list do
    Config.list_agents() |> Repo.preload(providers: :deployments)
  end

  defp detail(id) do
    agent = Config.get_agent!(id) |> Repo.preload(providers: :deployments)

    %{
      agent: agent,
      online: online?(agent.host_id),
      slots: Enum.map(agent.providers, &slot_view/1)
    }
  end

  # A managed Provider is a slot; its resident model is the deployment currently
  # reporting `:up` under it (Ingest marks the resident deployment up and the
  # rest down). `:unknown` on a deployment means the slot is loading.
  defp slot_view(provider) do
    {resident, status} = resident(provider)

    %{
      provider: provider,
      resident_model: resident,
      status: status,
      deployment_count: length(provider.deployments)
    }
  end

  defp resident(provider) do
    statuses = Enum.map(provider.deployments, &{&1.model_name, Health.status(&1.id)})

    cond do
      hit = Enum.find(statuses, fn {_m, s} -> s == :up end) -> {elem(hit, 0), "up"}
      Enum.any?(statuses, fn {_m, s} -> s == :unknown end) -> {nil, "unknown"}
      true -> {nil, "down"}
    end
  end

  defp online_map(agents), do: Map.new(agents, &{&1.host_id, online?(&1.host_id)})

  # Presence is the poll-free liveness signal: a connected agent tracks itself on
  # its own `agent:<host_id>` topic (see `AiroWeb.AgentChannel`). Reads local
  # Presence ETS for the current truth; the subscription delivers the changes.
  defp online?(host_id), do: Presence.list("agent:#{host_id}") != %{}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="agents">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle={agents_subtitle(@live_action, @detail)}>
          <:crumb navigate={~p"/admin/agents"}>Agents</:crumb>
          <:crumb :if={@live_action == :show}>{@detail.agent.host_id}</:crumb>
          <:actions :if={@live_action == :show}>
            <.button size="sm" navigate={~p"/admin/agents"}>Back</.button>
          </:actions>
        </CompositeComponents.page_header>

        <%= if @detail do %>
          <.agent_detail detail={@detail} />
        <% else %>
          <.agent_table agents={@agents} online={@online} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp agents_subtitle(:show, _detail), do: "Host control plane: GPU posture and managed slots."
  defp agents_subtitle(_index, _detail), do: "Host-side control agents managing serving slots."

  attr :agents, :list, required: true
  attr :online, :map, required: true

  defp agent_table(assigns) do
    ~H"""
    <CompositeComponents.empty_state
      :if={@agents == []}
      icon="hero-server-stack"
      title="No agents registered"
    >
      A host running <span class="font-mono">airo_agent</span>
      registers itself here when it connects. Set <span class="font-mono">AIRO_SOCKET_URL</span>
      on the host to point at this server's <span class="font-mono">/agent</span>
      socket.
    </CompositeComponents.empty_state>

    <.table
      :if={@agents != []}
      id="agents"
      rows={@agents}
      row_click={fn agent -> JS.navigate(~p"/admin/agents/#{agent.id}") end}
    >
      <:col :let={agent} label="Host">{agent.host_id}</:col>
      <:col :let={agent} label="Status">
        <.presence_tag online={@online[agent.host_id]} />
      </:col>
      <:col :let={agent} label="GPU / VRAM">{gpu_summary(agent.gpu)}</:col>
      <:col :let={agent} label="Util">{gpu_util(agent.gpu)}</:col>
      <:col :let={agent} label="Slots">{length(agent.providers)}</:col>
      <:col :let={agent} label="Version">{present(agent.version)}</:col>
      <:col :let={agent} label="Last seen">{format_at(agent.last_seen_at)}</:col>
      <:action :let={agent}>
        <.icon_button
          icon="hero-arrow-top-right-on-square"
          label={"Open #{agent.host_id}"}
          navigate={~p"/admin/agents/#{agent.id}"}
        />
      </:action>
    </.table>
    """
  end

  attr :detail, :map, required: true

  defp agent_detail(assigns) do
    assigns = assign(assigns, loaded: Enum.count(assigns.detail.slots, &(&1.status == "up")))

    ~H"""
    <div class="space-y-6">
      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <CompositeComponents.stat_tile label="Status">
          <.presence_tag online={@detail.online} />
        </CompositeComponents.stat_tile>
        <CompositeComponents.stat_tile label="Slots">
          {length(@detail.slots)}
          <:sub :if={@detail.slots != []}>{@loaded} loaded</:sub>
        </CompositeComponents.stat_tile>
        <CompositeComponents.stat_tile label="Version">
          {present(@detail.agent.version)}
        </CompositeComponents.stat_tile>
        <CompositeComponents.stat_tile label="Last seen">
          <span class="text-base">{format_at(@detail.agent.last_seen_at)}</span>
        </CompositeComponents.stat_tile>
      </div>

      <.card variant="bordered">
        <:title>GPU posture</:title>
        <%= if gpu_available?(@detail.agent.gpu) do %>
          <div class="mt-2 space-y-5">
            <CompositeComponents.meter
              label="VRAM"
              value={gpu_val(@detail.agent.gpu, :vram_used_mb)}
              max={gpu_val(@detail.agent.gpu, :vram_total_mb)}
              display={gpu_summary(@detail.agent.gpu)}
            />
            <CompositeComponents.meter
              label="GPU utilization"
              value={gpu_val(@detail.agent.gpu, :util_pct)}
              max={100}
            />
            <CompositeComponents.meter
              label="Power draw"
              value={gpu_val(@detail.agent.gpu, :power_draw_w)}
              max={gpu_val(@detail.agent.gpu, :power_limit_w)}
              display={gpu_power(@detail.agent.gpu)}
            />
          </div>
        <% else %>
          <p class="mt-1 text-sm text-base-content/55">No GPU telemetry reported by this host.</p>
        <% end %>
      </.card>

      <.card variant="bordered">
        <:title>Managed slots</:title>
        <CompositeComponents.empty_state
          :if={@detail.slots == []}
          icon="hero-square-3-stack-3d"
          title="No slots yet"
        >
          This agent hasn't registered any serving slots. They appear once it
          advertises its engine ports to Airo.
        </CompositeComponents.empty_state>
        <.table
          :if={@detail.slots != []}
          id="agent-slots"
          rows={@detail.slots}
          row_click={fn slot -> JS.navigate(~p"/admin/providers/#{slot.provider.id}") end}
        >
          <:col :let={slot} label="Slot">{slot.provider.name}</:col>
          <:col :let={slot} label="Base URL">
            <span class="font-mono text-xs">{slot.provider.base_url}</span>
          </:col>
          <:col :let={slot} label="Resident model">
            <span class={[is_nil(slot.resident_model) && "text-base-content/40"]}>
              {present(slot.resident_model)}
            </span>
          </:col>
          <:col :let={slot} label="Status">
            <CompositeComponents.health_status status={slot.status} />
          </:col>
          <:col :let={slot} label="Deployments">{slot.deployment_count}</:col>
          <:action :let={slot}>
            <.icon_button
              icon="hero-arrow-top-right-on-square"
              label={"Open #{slot.provider.name}"}
              navigate={~p"/admin/providers/#{slot.provider.id}"}
            />
          </:action>
        </.table>
      </.card>

      <.card variant="bordered">
        <:title>Control plane</:title>
        <dl class="grid gap-4 text-sm sm:grid-cols-3">
          <div>
            <dt class="text-xs uppercase tracking-wide text-base-content/45">Host id</dt>
            <dd class="mt-0.5 font-mono">{@detail.agent.host_id}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase tracking-wide text-base-content/45">Control URL</dt>
            <dd class="mt-0.5 font-mono">{@detail.agent.control_url}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase tracking-wide text-base-content/45">Enabled</dt>
            <dd class="mt-0.5">{@detail.agent.enabled}</dd>
          </div>
        </dl>
      </.card>
    </div>
    """
  end

  attr :online, :boolean, required: true

  defp presence_tag(%{online: true} = assigns),
    do: ~H|<CompositeComponents.tag tone="success">online</CompositeComponents.tag>|

  defp presence_tag(assigns),
    do: ~H|<CompositeComponents.tag tone="neutral">offline</CompositeComponents.tag>|

  # --- GPU formatting (channel pushes a JSON map → string keys) ---

  defp gpu_available?(gpu), do: gpu_val(gpu, :available) == true

  defp gpu_summary(gpu) do
    used = gpu_val(gpu, :vram_used_mb)
    total = gpu_val(gpu, :vram_total_mb)

    cond do
      is_number(used) and is_number(total) -> "#{gb(used)} / #{gb(total)} GB"
      is_number(total) -> "#{gb(total)} GB"
      true -> "—"
    end
  end

  defp gpu_util(gpu) do
    case gpu_val(gpu, :util_pct) do
      pct when is_number(pct) -> "#{round(pct)}%"
      _ -> "—"
    end
  end

  defp gpu_power(gpu) do
    draw = gpu_val(gpu, :power_draw_w)
    limit = gpu_val(gpu, :power_limit_w)

    cond do
      is_number(draw) and is_number(limit) -> "#{round(draw)} / #{round(limit)} W"
      is_number(draw) -> "#{round(draw)} W"
      true -> "—"
    end
  end

  defp gpu_val(gpu, key) when is_map(gpu), do: Map.get(gpu, key) || Map.get(gpu, to_string(key))
  defp gpu_val(_gpu, _key), do: nil

  defp gb(mb) when is_number(mb), do: Float.round(mb / 1024, 1)

  defp present(value) when value in [nil, ""], do: "—"
  defp present(value), do: value

  defp format_at(nil), do: "—"
  defp format_at(%DateTime{} = at), do: Calendar.strftime(at, "%b %d  %H:%M:%S")
end
