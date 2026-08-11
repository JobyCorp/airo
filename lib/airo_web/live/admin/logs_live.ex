defmodule AiroWeb.Admin.LogsLive do
  @moduledoc """
  Operational event log (DESIGN-logging-traceability.md): routing predictions and
  health transitions, filterable and correlated by `trace_id`. Distinct from
  `/admin/usage`, which stays consumption-focused.
  """
  use AiroWeb, :live_view

  alias Airo.Logs
  alias AiroWeb.CompositeComponents

  @default_filters %{
    "kind" => "",
    "level" => "",
    "range" => "24h",
    "alias" => "",
    "predicted_class" => "",
    "trace_id" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Logs.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: "Logs",
       streaming: connected?(socket),
       kind_options: optionize(Logs.kind_options()),
       level_options: optionize(Logs.level_options())
     )
     |> load(@default_filters)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply, load(socket, normalize_filters(params))}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, load(socket, @default_filters)}
  end

  # Live feed: a freshly captured event arrives via PubSub. Prepend it if it still
  # matches the active filters (new events are always within any time range), and
  # bump the counts — no re-query needed.
  @impl true
  def handle_info({:log_event, event}, socket) do
    if matches?(event, socket.assigns.filters) do
      {:noreply,
       socket
       |> stream_insert(:events, event, at: 0)
       |> assign(summary: bump(socket.assigns.summary, event))}
    else
      {:noreply, socket}
    end
  end

  defp load(socket, filters) do
    socket
    |> assign(
      filters: filters,
      filter_form: to_form(filters, as: :filters),
      summary: Logs.summary(filters)
    )
    |> stream(:events, Logs.list(filters, 200), reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="logs">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle="Operational events — routing predictions and health transitions, correlated by trace.">
          <:crumb>Logs</:crumb>
          <:actions>
            <span
              :if={@streaming}
              class="inline-flex items-center gap-1.5 text-xs font-medium text-success"
            >
              <span class="relative flex size-2">
                <span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-75" />
                <span class="relative inline-flex size-2 rounded-full bg-success" />
              </span>
              Live
            </span>
            <.button id="logs-header-reset" size="sm" phx-click="reset">
              Reset filters
            </.button>
          </:actions>
        </CompositeComponents.page_header>

        <div class="grid gap-4 sm:grid-cols-3">
          <.card variant="bordered">
            <:eyebrow>Events</:eyebrow>
            <:title>{@summary.total}</:title>
            In the selected range.
          </.card>
          <.card variant="bordered">
            <:eyebrow>Warnings</:eyebrow>
            <:title>
              <span class={[@summary.warnings > 0 && "text-warning"]}>{@summary.warnings}</span>
            </:title>
            Degraded predictions or health.
          </.card>
          <.card variant="bordered">
            <:eyebrow>Errors</:eyebrow>
            <:title>
              <span class={[@summary.errors > 0 && "text-error"]}>{@summary.errors}</span>
            </:title>
            Failures worth a look.
          </.card>
        </div>

        <.card variant="bordered">
          <:title>Filters</:title>
          <.form
            for={@filter_form}
            id="logs-filters"
            phx-change="filter"
            class="grid gap-4 md:grid-cols-3 xl:grid-cols-6"
          >
            <.input
              field={@filter_form[:kind]}
              type="select"
              label="Kind"
              options={@kind_options}
              prompt="Any"
            />
            <.input
              field={@filter_form[:level]}
              type="select"
              label="Level"
              options={@level_options}
              prompt="Any"
            />
            <.input
              field={@filter_form[:range]}
              type="select"
              label="Range"
              options={[{"24 hours", "24h"}, {"1 hour", "1h"}, {"7 days", "7d"}, {"All", "all"}]}
            />
            <.input field={@filter_form[:alias]} label="Alias" placeholder="alias name" />
            <.input
              field={@filter_form[:predicted_class]}
              label="Predicted class"
              placeholder="edge / deep"
            />
            <.input field={@filter_form[:trace_id]} label="Trace" placeholder="gt_..." />
          </.form>
        </.card>

        <.table id="logs" rows={@streams.events}>
          <:col :let={{_id, e}} label="When">
            <span class="whitespace-nowrap font-mono text-xs text-base-content/55">
              {format_at(e.inserted_at)}
            </span>
          </:col>
          <:col :let={{_id, e}} label="Level">
            <CompositeComponents.tag tone={level_tone(e.level)}>{e.level}</CompositeComponents.tag>
          </:col>
          <:col :let={{_id, e}} label="Event">
            <div class="flex min-w-0 flex-col gap-1">
              <div class="flex flex-wrap items-center gap-1.5">
                <CompositeComponents.tag tone={kind_tone(e.kind)}>
                  {kind_label(e.kind)}
                </CompositeComponents.tag>
                <%= case e.kind do %>
                  <% :route_prediction -> %>
                    <span class="font-medium text-base-content">{e.alias_name || "—"}</span>
                    <.icon name="hero-arrow-right" class="size-4 text-base-content/30" />
                    <CompositeComponents.tag tone={tier_tone(e.data["predicted_class"])}>
                      {e.data["predicted_class"] || "—"}
                    </CompositeComponents.tag>
                    <span
                      :if={e.data["applied"] == true}
                      class="inline-flex items-center gap-1 text-xs text-success"
                    >
                      <.icon name="hero-check-circle" class="size-4" /> applied
                    </span>
                  <% :health -> %>
                    <span class="font-medium text-base-content">
                      deployment {e.deployment_id || "?"}
                    </span>
                    <.icon name="hero-arrow-right" class="size-4 text-base-content/30" />
                    <CompositeComponents.tag tone={status_tone(e.data["status"])}>
                      {e.data["status"]}
                    </CompositeComponents.tag>
                  <% _ -> %>
                    <span class="text-base-content/70">{e.summary}</span>
                <% end %>
              </div>
              <span
                :if={event_meta(e) != ""}
                class="truncate font-mono text-xs text-base-content/45"
              >
                {event_meta(e)}
              </span>
            </div>
          </:col>
          <:col :let={{_id, e}} label="Trace">
            <.link
              :if={e.trace_id}
              navigate={~p"/admin/logs/#{e.trace_id}"}
              class="font-mono text-xs text-primary hover:underline"
            >
              {e.trace_id}
            </.link>
            <span :if={!e.trace_id} class="text-base-content/30">—</span>
          </:col>
          <:action :let={{_id, e}}>
            <.button
              :if={e.trace_id}
              shape="square"
              size="sm"
              variant="ghost"
              title="Open trace timeline"
              aria-label="Open trace timeline"
              navigate={~p"/admin/logs/#{e.trace_id}"}
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </.button>
          </:action>
        </.table>
      </div>
    </Layouts.app>
    """
  end

  defp normalize_filters(params),
    do: Map.merge(@default_filters, Map.take(params, Map.keys(@default_filters)))

  defp optionize(values), do: Enum.map(values, &{humanize(&1), to_string(&1)})

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  ## Row presentation

  defp kind_label(:route_prediction), do: "route"
  defp kind_label(:health), do: "health"
  defp kind_label(other), do: to_string(other)

  defp kind_tone(:route_prediction), do: "primary"
  defp kind_tone(_), do: "neutral"

  defp level_tone(:error), do: "error"
  defp level_tone(:warning), do: "warning"
  defp level_tone(_), do: "neutral"

  defp tier_tone("edge"), do: "success"
  defp tier_tone("deep"), do: "warning"
  defp tier_tone("cloud"), do: "primary"
  defp tier_tone(_), do: "neutral"

  defp status_tone("up"), do: "success"
  defp status_tone("down"), do: "error"
  defp status_tone(_), do: "neutral"

  # The muted secondary line under the event title — the structured detail that
  # used to be crammed into the raw summary string.
  defp event_meta(%{kind: :route_prediction, data: data}) do
    [data["mode"], score_str(data), latency_str(data["latency_ms"])]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp event_meta(%{kind: :health, data: data}) do
    [data["source"], data["reason"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp event_meta(_), do: ""

  defp score_str(%{"predicted_class" => class, "scores" => scores})
       when is_binary(class) and is_map(scores) do
    case scores[class] do
      score when is_number(score) -> "score #{Float.round(score, 3)}"
      _ -> nil
    end
  end

  defp score_str(_), do: nil

  defp latency_str(ms) when is_integer(ms), do: "#{ms}ms"
  defp latency_str(_), do: nil

  defp format_at(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%b %d  %H:%M:%S")
  defp format_at(other), do: to_string(other)

  ## Live-feed filter matching (mirrors query/1; a new event is always in-range)

  defp matches?(event, filters) do
    eq?(filters["kind"], to_string(event.kind)) and
      eq?(filters["level"], to_string(event.level)) and
      sub?(filters["alias"], event.alias_name) and
      eq?(filters["predicted_class"], event.data["predicted_class"]) and
      sub?(filters["trace_id"], event.trace_id)
  end

  defp eq?(blank, _value) when blank in [nil, ""], do: true
  defp eq?(filter, value), do: filter == value

  defp sub?(blank, _value) when blank in [nil, ""], do: true
  defp sub?(_filter, nil), do: false

  defp sub?(filter, value),
    do: String.contains?(String.downcase(value), String.downcase(filter))

  defp bump(summary, event) do
    summary
    |> Map.update!(:total, &(&1 + 1))
    |> Map.update!(:warnings, &(&1 + bool(event.level == :warning)))
    |> Map.update!(:errors, &(&1 + bool(event.level == :error)))
  end

  defp bool(true), do: 1
  defp bool(false), do: 0
end
