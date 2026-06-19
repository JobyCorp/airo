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
    {:ok,
     socket
     |> assign(
       page_title: "Logs",
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
            <.button id="logs-header-reset" size="sm" phx-click="reset">Reset filters</.button>
          </:actions>
        </CompositeComponents.page_header>

        <div class="grid gap-4 md:grid-cols-3">
          <.card variant="bordered">
            <:eyebrow>Events</:eyebrow>
            <:title>{@summary.total}</:title>
            Matching records.
          </.card>
          <.card variant="bordered">
            <:eyebrow>Warnings</:eyebrow>
            <:title>{@summary.warnings}</:title>
            Level warning.
          </.card>
          <.card variant="bordered">
            <:eyebrow>Errors</:eyebrow>
            <:title>{@summary.errors}</:title>
            Level error.
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
          <:col :let={{_id, e}} label="When">{e.inserted_at}</:col>
          <:col :let={{_id, e}} label="Kind">{e.kind}</:col>
          <:col :let={{_id, e}} label="Level">{e.level}</:col>
          <:col :let={{_id, e}} label="Trace">
            <span class="font-mono text-xs">{e.trace_id || "—"}</span>
          </:col>
          <:col :let={{_id, e}} label="Alias">{e.alias_name || "—"}</:col>
          <:col :let={{_id, e}} label="Summary">
            <span class="text-xs">{e.summary}</span>
          </:col>
          <:action :let={{_id, e}}>
            <.icon_button
              :if={e.trace_id}
              icon="hero-magnifying-glass"
              label="Open trace timeline"
              navigate={~p"/admin/logs/#{e.trace_id}"}
            />
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
end
