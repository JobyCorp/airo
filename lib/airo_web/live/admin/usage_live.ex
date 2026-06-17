defmodule AiroWeb.Admin.UsageLive do
  @moduledoc "Read-only usage view: recent records + total cost (DESIGN §10)."
  use AiroWeb, :live_view

  alias Airo.Usage
  alias AiroWeb.CompositeComponents

  @default_filters %{
    "range" => "24h",
    "outcome" => "",
    "client_key_id" => "",
    "capability" => "",
    "model" => "",
    "trace_id" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    filters = @default_filters
    records = Usage.list_usage_records(filters, 200)

    {:ok,
     socket
     |> assign(
       page_title: "Usage",
       filters: filters,
       filter_form: to_form(filters, as: :filters),
       summary: Usage.usage_summary(filters),
       client_options: Usage.client_options(),
       capability_options: optionize(Usage.capability_options()),
       outcome_options: optionize(Usage.outcome_options())
     )
     |> stream(:records, records)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = normalize_filters(params)
    records = Usage.list_usage_records(filters, 200)

    {:noreply,
     socket
     |> assign(
       filters: filters,
       filter_form: to_form(filters, as: :filters),
       summary: Usage.usage_summary(filters)
     )
     |> stream(:records, records, reset: true)}
  end

  def handle_event("reset", _params, socket) do
    filters = @default_filters
    records = Usage.list_usage_records(filters, 200)

    {:noreply,
     socket
     |> assign(
       filters: filters,
       filter_form: to_form(filters, as: :filters),
       summary: Usage.usage_summary(filters)
     )
     |> stream(:records, records, reset: true)}
  end

  def handle_event("trace", %{"id" => trace_id}, socket) do
    filters =
      socket.assigns.filters
      |> Map.put("trace_id", trace_id)
      |> Map.put("range", "all")

    records = Usage.list_usage_records(filters, 200)

    {:noreply,
     socket
     |> assign(
       filters: filters,
       filter_form: to_form(filters, as: :filters),
       summary: Usage.usage_summary(filters)
     )
     |> stream(:records, records, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="usage">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle="Traceable gateway traffic, failures, latency, and cost.">
          <:crumb>Usage</:crumb>
          <:actions>
            <.button id="usage-header-reset" size="sm" phx-click="reset">Reset filters</.button>
          </:actions>
        </CompositeComponents.page_header>

        <div class="grid gap-4 md:grid-cols-3 xl:grid-cols-6">
          <.card variant="bordered">
            <:eyebrow>Requests</:eyebrow>
            <:title>{@summary.total}</:title>
            Matching records.
          </.card>
          <.card variant="bordered">
            <:eyebrow>Error rate</:eyebrow>
            <:title>{@summary.error_rate}</:title>
            {@summary.errors} failed.
          </.card>
          <.card variant="bordered">
            <:eyebrow>p50 latency</:eyebrow>
            <:title>{latency(@summary.p50_latency_ms)}</:title>
            Milliseconds.
          </.card>
          <.card variant="bordered">
            <:eyebrow>p95 latency</:eyebrow>
            <:title>{latency(@summary.p95_latency_ms)}</:title>
            Milliseconds.
          </.card>
          <.card variant="bordered">
            <:eyebrow>Fallbacks</:eyebrow>
            <:title>{@summary.fallback_count}</:title>
            Served by later candidates.
          </.card>
          <.card variant="bordered">
            <:eyebrow>Cost</:eyebrow>
            <:title>{@summary.total_cost}</:title>
            Matching records.
          </.card>
        </div>

        <.card variant="bordered">
          <:title>Filters</:title>
          <.form
            for={@filter_form}
            id="usage-filters"
            phx-change="filter"
            class="grid gap-4 md:grid-cols-3 xl:grid-cols-6"
          >
            <.input
              field={@filter_form[:range]}
              type="select"
              label="Range"
              options={[{"24 hours", "24h"}, {"1 hour", "1h"}, {"7 days", "7d"}, {"All", "all"}]}
            />
            <.input
              field={@filter_form[:outcome]}
              type="select"
              label="Outcome"
              options={@outcome_options}
              prompt="Any"
            />
            <.input
              field={@filter_form[:client_key_id]}
              type="select"
              label="Client"
              options={@client_options}
              prompt="Any"
            />
            <.input
              field={@filter_form[:capability]}
              type="select"
              label="Capability"
              options={@capability_options}
              prompt="Any"
            />
            <.input field={@filter_form[:model]} label="Model" placeholder="alias or model id" />
            <.input field={@filter_form[:trace_id]} label="Trace" placeholder="gt_..." />
          </.form>
        </.card>

        <.table
          id="usage"
          rows={@streams.records}
          row_click={
            fn {_id, r} ->
              r.trace_id && JS.push("trace", value: %{id: r.trace_id})
            end
          }
        >
          <:col :let={{_id, r}} label="When">{r.inserted_at}</:col>
          <:col :let={{_id, r}} label="Client">{r.client_key && r.client_key.name}</:col>
          <:col :let={{_id, r}} label="Trace">
            <span class="font-mono text-xs">{r.trace_id || "—"}</span>
          </:col>
          <:col :let={{_id, r}} label="Requested">{r.request_model || r.alias_name}</:col>
          <:col :let={{_id, r}} label="Capability">{r.capability}</:col>
          <:col :let={{_id, r}} label="Served">{r.deployment && r.deployment.model_name}</:col>
          <:col :let={{_id, r}} label="Status">{status_label(r)}</:col>
          <:col :let={{_id, r}} label="Error">{r.error_code || "—"}</:col>
          <:col :let={{_id, r}} label="Tokens">{r.tokens_in}/{r.tokens_out}</:col>
          <:col :let={{_id, r}} label="Latency">{latency(r.latency_ms)}</:col>
          <:col :let={{_id, r}} label="Fallback">{if r.fallback_used, do: "yes", else: "no"}</:col>
          <:col :let={{_id, r}} label="Cost">{r.cost}</:col>
          <:action :let={{_id, r}}>
            <.icon_button
              :if={r.trace_id}
              icon="hero-funnel"
              label="Filter to this trace"
              phx-click="trace"
              phx-value-id={r.trace_id}
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

  defp humanize(value) do
    value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp latency(nil), do: "—"
  defp latency(ms), do: "#{ms} ms"

  defp status_label(%{outcome: :success}), do: "success"
  defp status_label(%{http_status: status}) when is_integer(status), do: "HTTP #{status}"
  defp status_label(%{outcome: outcome}), do: to_string(outcome)
end
