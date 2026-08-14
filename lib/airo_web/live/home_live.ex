defmodule AiroWeb.HomeLive do
  @moduledoc "Operational dashboard for the Airo gateway."

  use AiroWeb, :live_view

  import AiroWeb.Time, only: [format_at: 1]

  alias Airo.Dashboard
  alias AiroWeb.CompositeComponents
  alias AiroWeb.Presence

  # GPU telemetry is DB state the host agents push over their channel; a light
  # timer re-reads the overview so the host rings stay live without a reload.
  # Online/offline is faster still — a Presence subscription flips it instantly.
  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    overview = Dashboard.overview()

    {:ok,
     socket
     |> assign(page_title: "Airo overview", subscribed: MapSet.new())
     |> assign(overview: overview)
     |> assign(agents: with_presence(overview.agents))
     |> subscribe_agents(overview.agents)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    overview = Dashboard.overview()

    {:noreply,
     socket
     |> assign(overview: overview, agents: with_presence(overview.agents))
     |> subscribe_agents(overview.agents)}
  end

  # A host connected or dropped — re-derive the online flags from Presence
  # without re-running the heavier overview query.
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, agents: with_presence(socket.assigns.overview.agents))}
  end

  # The agent topic also carries channel control messages; ignore the rest.
  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  # Watch each host's Presence topic so up/down flips arrive as a push. Tracks
  # which hosts we already hold so re-listing never double-subscribes.
  defp subscribe_agents(%{assigns: %{subscribed: subscribed}} = socket, agents) do
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

  defp with_presence(agents) do
    Enum.map(agents, &Map.put(&1, :online, Presence.list("agent:#{&1.host_id}") != %{}))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="home">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <h1 class="sr-only">Airo overview</h1>

        <CompositeComponents.page_header subtitle="Gateway posture, traffic, local capacity, and model performance.">
          <:crumb>Overview</:crumb>
          <:actions>
            <.button size="sm" navigate={~p"/admin/models"}>Models</.button>
            <.button size="sm" navigate={~p"/admin/usage"} variant="primary">Usage</.button>
          </:actions>
        </CompositeComponents.page_header>

        <CompositeComponents.section_panel :if={@agents != []} body_class="p-4">
          <:title>Serving hosts</:title>
          <:actions>
            <.button size="sm" navigate={~p"/admin/agents"}>All agents</.button>
          </:actions>
          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            <.agent_ring_card :for={agent <- @agents} agent={agent} />
          </div>
        </CompositeComponents.section_panel>

        <div class="grid gap-4 md:grid-cols-3 xl:grid-cols-6">
          <.metric_card
            label="Requests"
            value={@overview.usage.total}
            note="Last 24 hours"
            accent="info"
          />
          <.metric_card
            label="Error rate"
            value={@overview.usage.error_rate}
            note={"#{@overview.usage.errors} failed"}
            accent="error"
          />
          <.metric_card
            label="p50 latency"
            value={latency(@overview.usage.p50_latency_ms)}
            note="Served calls"
            accent="success"
          />
          <.metric_card
            label="p95 latency"
            value={latency(@overview.usage.p95_latency_ms)}
            note="Tail latency"
            accent="warning"
          />
          <.metric_card
            label="Deployments"
            value={length(@overview.deployments)}
            note={health_note(@overview.health_counts)}
            accent="neutral"
          />
          <.metric_card
            label="Models"
            value={@overview.model_posture.total}
            note={"#{@overview.model_posture.healthy} healthy"}
            accent="neutral"
          />
        </div>

        <div class="grid gap-5 xl:grid-cols-[1.15fr_0.85fr]">
          <CompositeComponents.section_panel body_class="p-0">
            <:title>Performance monitor</:title>
            <:actions>
              <.button size="sm" navigate={~p"/admin/usage"}>Open usage</.button>
            </:actions>
            <div class="grid divide-y divide-base-content/10 xl:grid-cols-2 xl:divide-x xl:divide-y-0">
              <.chart_panel
                id="request-volume-chart"
                title="Request volume"
                subtitle="Requests, errors, and fallbacks"
                kind="volume"
                performance={@overview.performance}
              />
              <.chart_panel
                id="latency-chart"
                title="Latency"
                subtitle="p50 and p95 by time bucket"
                kind="latency"
                performance={@overview.performance}
              />
            </div>
          </CompositeComponents.section_panel>

          <CompositeComponents.section_panel>
            <:title>Capacity posture</:title>
            <div class="grid gap-3">
              <.capacity_row
                label="Providers"
                value={length(@overview.providers)}
                href={~p"/admin/providers"}
              />
              <.capacity_row
                label="Aliases"
                value={length(@overview.aliases)}
                href={~p"/admin/aliases"}
              />
              <.capacity_row
                label="Client keys"
                value={length(@overview.client_keys)}
                href={~p"/admin/keys"}
              />
              <div class="grid grid-cols-3 gap-2 pt-2">
                <.health_count value={@overview.health_counts.up} status="up" />
                <.health_count value={@overview.health_counts.down} status="down" />
                <.health_count value={@overview.health_counts.unknown} status="unknown" />
              </div>
            </div>
          </CompositeComponents.section_panel>
        </div>

        <div class="grid gap-5 xl:grid-cols-[1.1fr_0.9fr]">
          <CompositeComponents.section_panel body_class="p-4">
            <:title>Model posture</:title>
            <:actions>
              <.button size="sm" navigate={~p"/admin/models"}>Model shelf</.button>
            </:actions>
            <.data_table
              id="dashboard-models"
              rows={@overview.model_posture.top}
              row_click={fn summary -> JS.navigate(~p"/admin/models/#{summary.model.id}") end}
            >
              <:col :let={summary} label="Model">
                <div class="font-medium text-base-content">{summary.model.display_name}</div>
                <div class="font-mono text-xs text-base-content/55">
                  {summary.model.upstream_model_id}
                </div>
              </:col>
              <:col :let={summary} label="Health">
                <CompositeComponents.health_status status={to_string(summary.health)} />
              </:col>
              <:col :let={summary} label="Requests">{summary.requests}</:col>
              <:col :let={summary} label="p95">{latency(summary.p95_latency_ms)}</:col>
              <:col :let={summary} label="Deployments">
                {summary.enabled_deployment_count}/{summary.deployment_count}
              </:col>
            </.data_table>
          </CompositeComponents.section_panel>

          <CompositeComponents.section_panel>
            <:title>Attention queue</:title>
            <div class="space-y-4">
              <.attention_list title="Watch" models={@overview.model_posture.watch} tone="warning" />
              <.attention_list
                title="Needs traffic"
                models={@overview.model_posture.needs_traffic}
                tone="info"
              />
            </div>
          </CompositeComponents.section_panel>
        </div>

        <div class="grid gap-5 xl:grid-cols-2">
          <CompositeComponents.section_panel body_class="p-4">
            <:title>Providers</:title>
            <.data_table
              id="dashboard-providers"
              rows={@overview.provider_posture}
              row_click={fn posture -> JS.navigate(~p"/admin/providers/#{posture.provider.id}") end}
            >
              <:col :let={posture} label="Provider">{posture.provider.name}</:col>
              <:col :let={posture} label="Type">{posture.provider.adapter_type}</:col>
              <:col :let={posture} label="Health">
                <CompositeComponents.health_status status={to_string(posture.status)} />
              </:col>
              <:col :let={posture} label="Enabled">
                {posture.enabled_deployment_count}/{posture.deployment_count}
              </:col>
            </.data_table>
          </CompositeComponents.section_panel>

          <CompositeComponents.section_panel body_class="p-4">
            <:title>Recent traces</:title>
            <.data_table id="dashboard-usage" rows={@overview.recent_usage}>
              <:col :let={record} label="Trace">
                <span class="font-mono text-xs">{record.trace_id || "—"}</span>
              </:col>
              <:col :let={record} label="Requested">{record.request_model || record.alias_name}</:col>
              <:col :let={record} label="Outcome">{record.outcome}</:col>
              <:col :let={record} label="Latency">{latency(record.latency_ms)}</:col>
            </.data_table>
          </CompositeComponents.section_panel>
        </div>

        <CompositeComponents.section_panel body_class="p-4">
          <:title>Recent health transitions</:title>
          <.data_table id="dashboard-health-events" rows={@overview.recent_health_events}>
            <:col :let={event} label="When">{format_at(event.inserted_at)}</:col>
            <:col :let={event} label="Provider">{event.provider && event.provider.name}</:col>
            <:col :let={event} label="Model">{event.deployment && event.deployment.model_name}</:col>
            <:col :let={event} label="Status">
              <CompositeComponents.health_status status={to_string(event.status)} />
            </:col>
            <:col :let={event} label="Reason">{event.reason || "—"}</:col>
          </.data_table>
        </CompositeComponents.section_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :agent, :map, required: true

  # A serving host as three concentric activity rings — VRAM (outer), compute
  # (middle), power (inner) — with the host id and its slot count in the center.
  # Each ring's color is fixed to its metric so the trio reads at a glance; the
  # arc length is the live fraction. Offline or no-telemetry rings sit empty.
  defp agent_ring_card(assigns) do
    radii = [56, 43, 30]

    rings =
      assigns.agent.rings
      |> Enum.zip(radii)
      |> Enum.map(fn {ring, r} ->
        circ = 2 * :math.pi() * r

        Map.merge(ring, %{
          r: r,
          circ: Float.round(circ, 2),
          offset: Float.round(circ * (1 - (ring.fraction || 0.0)), 2)
        })
      end)

    assigns = assign(assigns, rings: rings)

    ~H"""
    <.link
      navigate={~p"/admin/agents/#{@agent.id}"}
      class="group relative block rounded-box border border-base-300 bg-base-100 p-5 transition-colors hover:border-base-content/25"
    >
      <span class="absolute right-3 top-3 inline-flex items-center gap-1.5">
        <span class={[
          "size-2 rounded-full",
          @agent.online && "bg-success",
          !@agent.online && "bg-base-content/30"
        ]} />
        <span class="text-[0.65rem] font-medium uppercase tracking-[0.14em] text-base-content/50">
          {if @agent.online, do: "online", else: "offline"}
        </span>
      </span>

      <div class="relative mx-auto aspect-square w-40">
        <svg viewBox="0 0 132 132" class="size-full -rotate-0" aria-hidden="true">
          <g :for={ring <- @rings}>
            <circle
              cx="66"
              cy="66"
              r={ring.r}
              fill="none"
              stroke="currentColor"
              stroke-width="9"
              class="text-base-content/10"
            />
            <circle
              cx="66"
              cy="66"
              r={ring.r}
              fill="none"
              stroke-width="9"
              stroke-linecap="round"
              stroke-dasharray={ring.circ}
              stroke-dashoffset={ring.offset}
              transform="rotate(-90 66 66)"
              style={"stroke: #{ring_color(ring.tone)}"}
              class="transition-[stroke-dashoffset] duration-700 ease-out"
            />
          </g>
        </svg>
        <div class="absolute inset-0 flex flex-col items-center justify-center px-6 text-center">
          <span class="max-w-full truncate text-sm font-semibold text-base-content">
            {@agent.host_id}
          </span>
          <span class="font-mono text-xs text-base-content/55">
            {@agent.slots} {if @agent.slots == 1, do: "slot", else: "slots"}
          </span>
        </div>
      </div>

      <dl class="mt-4 space-y-1.5">
        <div :for={ring <- @rings} class="flex items-center justify-between gap-2">
          <dt class="flex items-center gap-2 text-xs text-base-content/65">
            <span class="size-2 rounded-full" style={"background: #{ring_color(ring.tone)}"} />
            {ring.label}
          </dt>
          <dd class="font-mono text-xs tabular-nums text-base-content/85">{ring.display}</dd>
        </div>
      </dl>
    </.link>
    """
  end

  defp ring_color("primary"), do: "var(--color-primary)"
  defp ring_color("success"), do: "var(--color-success)"
  defp ring_color("warning"), do: "var(--color-warning)"
  defp ring_color(_), do: "var(--color-base-content)"

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, required: true
  attr :accent, :string, values: ~w(info success warning error neutral), default: "neutral"

  defp metric_card(assigns) do
    ~H"""
    <.card variant="bordered" class={["border-l-4", metric_accent(@accent)]}>
      <:eyebrow>{@label}</:eyebrow>
      <:title>{@value}</:title>
      {@note}
    </.card>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :kind, :string, values: ~w(volume latency), required: true
  attr :performance, :map, required: true

  defp chart_panel(assigns) do
    assigns = assign(assigns, :any_traffic?, Enum.any?(assigns.performance.requests, &(&1 > 0)))

    ~H"""
    <div class="min-h-80 p-5">
      <div class="mb-4">
        <h3 class="text-sm font-semibold text-base-content">{@title}</h3>
        <p class="text-xs text-base-content/50">{@subtitle}</p>
      </div>
      <%!-- Vega derives the axis from the data, so an all-zero window plots a
           flat line against a "NaN" scale. A window with no traffic is a fact
           worth stating plainly rather than a chart worth drawing. --%>
      <div
        :if={!@any_traffic?}
        class="flex min-h-64 items-center justify-center rounded-md border border-dashed border-base-content/15 text-sm text-base-content/45"
      >
        No traffic in this window.
      </div>
      <div
        :if={@any_traffic?}
        id={@id}
        phx-hook="PerfChart"
        phx-update="ignore"
        data-chart-kind={@kind}
        data-chart={chart_json(@performance)}
        class="block min-h-64 w-full"
      >
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :href, :string, required: true

  defp capacity_row(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="flex items-center justify-between rounded-md border border-base-content/10 bg-base-100/45 px-3 py-2 transition-colors hover:bg-base-100/70"
    >
      <span class="text-sm text-base-content/65">{@label}</span>
      <span class="font-mono text-base text-base-content">{@value}</span>
    </.link>
    """
  end

  attr :value, :integer, required: true
  attr :status, :string, values: ~w(up down unknown), required: true

  # The pill already names the state, so there's no separate label — it read
  # "Up / 1 / Up" before, the same word twice in a tile three lines tall.
  defp health_count(assigns) do
    ~H"""
    <div class="rounded-md border border-base-content/10 bg-base-100/45 p-3">
      <CompositeComponents.health_status status={@status} />
      <div class="mt-2 font-mono text-lg text-base-content">{@value}</div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :models, :list, required: true
  attr :tone, :string, values: ~w(info warning), required: true

  defp attention_list(assigns) do
    ~H"""
    <div>
      <div class="mb-2 flex items-center gap-2">
        <span class={[
          "size-2 rounded-full",
          @tone == "warning" && "bg-warning",
          @tone == "info" && "bg-info"
        ]} />
        <h3 class="text-sm font-semibold text-base-content">{@title}</h3>
      </div>
      <div
        :if={@models == []}
        class="rounded-md border border-dashed border-base-content/15 bg-base-100/35 px-3 py-4 text-sm text-base-content/55"
      >
        Nothing to show.
      </div>
      <div :if={@models != []} class="space-y-2">
        <.link
          :for={summary <- @models}
          navigate={~p"/admin/models/#{summary.model.id}"}
          class="block rounded-md border border-base-content/10 bg-base-100/45 px-3 py-2 transition-colors hover:bg-base-100/70"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="truncate text-sm font-medium text-base-content">
              {summary.model.display_name}
            </span>
            <span class="shrink-0 font-mono text-xs text-base-content/60">
              {latency(summary.p95_latency_ms)}
            </span>
          </div>
          <div class="mt-1 text-xs text-base-content/50">
            {summary.requests} requests · {summary.error_rate} errors
          </div>
        </.link>
      </div>
    </div>
    """
  end

  defp metric_accent("info"), do: "border-l-info"
  defp metric_accent("success"), do: "border-l-success"
  defp metric_accent("warning"), do: "border-l-warning"
  defp metric_accent("error"), do: "border-l-error"
  # /40 rather than /25: at /25 the rule was invisible against the card border,
  # so Deployments and Models read as though their accent had been forgotten
  # next to the four that have one.
  defp metric_accent(_), do: "border-l-base-content/40"

  defp chart_json(performance), do: Jason.encode!(performance)

  defp health_note(%{up: up, down: down, unknown: unknown}),
    do: "#{up} up · #{down} down · #{unknown} unknown"

  defp latency(nil), do: "—"
  defp latency(ms), do: "#{ms} ms"
end
