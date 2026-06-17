defmodule AiroWeb.HomeLive do
  @moduledoc "Operational dashboard for the Airo gateway."

  use AiroWeb, :live_view

  alias Airo.Dashboard
  alias AiroWeb.CompositeComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Airo overview")
     |> assign(:overview, Dashboard.overview())}
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
                <.health_count label="Up" value={@overview.health_counts.up} status="up" />
                <.health_count label="Down" value={@overview.health_counts.down} status="down" />
                <.health_count
                  label="Unknown"
                  value={@overview.health_counts.unknown}
                  status="unknown"
                />
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
            <.table
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
            </.table>
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
            <.table
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
            </.table>
          </CompositeComponents.section_panel>

          <CompositeComponents.section_panel body_class="p-4">
            <:title>Recent traces</:title>
            <.table id="dashboard-usage" rows={@overview.recent_usage}>
              <:col :let={record} label="Trace">
                <span class="font-mono text-xs">{record.trace_id || "—"}</span>
              </:col>
              <:col :let={record} label="Requested">{record.request_model || record.alias_name}</:col>
              <:col :let={record} label="Outcome">{record.outcome}</:col>
              <:col :let={record} label="Latency">{latency(record.latency_ms)}</:col>
            </.table>
          </CompositeComponents.section_panel>
        </div>

        <CompositeComponents.section_panel body_class="p-4">
          <:title>Recent health transitions</:title>
          <.table id="dashboard-health-events" rows={@overview.recent_health_events}>
            <:col :let={event} label="When">{event.inserted_at}</:col>
            <:col :let={event} label="Provider">{event.provider && event.provider.name}</:col>
            <:col :let={event} label="Model">{event.deployment && event.deployment.model_name}</:col>
            <:col :let={event} label="Status">
              <CompositeComponents.health_status status={to_string(event.status)} />
            </:col>
            <:col :let={event} label="Reason">{event.reason || "—"}</:col>
          </.table>
        </CompositeComponents.section_panel>
      </div>
    </Layouts.app>
    """
  end

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
    ~H"""
    <div class="min-h-80 p-5">
      <div class="mb-4">
        <h3 class="text-sm font-semibold text-base-content">{@title}</h3>
        <p class="text-xs text-base-content/50">{@subtitle}</p>
      </div>
      <div
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

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :status, :string, values: ~w(up down unknown), required: true

  defp health_count(assigns) do
    ~H"""
    <div class="rounded-md border border-base-content/10 bg-base-100/45 p-3">
      <CompositeComponents.health_status status={@status} />
      <div class="mt-2 font-mono text-lg text-base-content">{@value}</div>
      <div class="text-xs text-base-content/50">{@label}</div>
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
  defp metric_accent(_), do: "border-l-base-content/25"

  defp chart_json(performance), do: Jason.encode!(performance)

  defp health_note(%{up: up, down: down, unknown: unknown}),
    do: "#{up} up · #{down} down · #{unknown} unknown"

  defp latency(nil), do: "—"
  defp latency(ms), do: "#{ms} ms"
end
