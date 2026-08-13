defmodule AiroWeb.Admin.UsageLive do
  @moduledoc "Read-only usage view: recent records + total cost (DESIGN §10)."
  use AiroWeb, :live_view

  import AiroWeb.Time, only: [format_at: 1]

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

    {:ok,
     socket
     |> assign(
       page_title: "Usage",
       show_routing: false,
       client_options: Usage.client_options(),
       capability_options: optionize(Usage.capability_options()),
       outcome_options: optionize(Usage.outcome_options())
     )
     |> apply_filters(filters)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply, apply_filters(socket, normalize_filters(params))}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, apply_filters(socket, @default_filters)}
  end

  def handle_event("toggle_routing", _params, socket) do
    {:noreply, assign(socket, show_routing: !socket.assigns.show_routing)}
  end

  def handle_event("trace", %{"id" => trace_id}, socket) do
    filters =
      socket.assigns.filters
      |> Map.put("trace_id", trace_id)
      |> Map.put("range", "all")

    {:noreply, apply_filters(socket, filters)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="usage">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle="Traceable gateway traffic, failures, latency, and cost.">
          <:crumb>Usage</:crumb>
          <:actions>
            <.button id="usage-toggle-routing" size="sm" variant="ghost" phx-click="toggle_routing">
              {if @show_routing, do: "Hide routing", else: "Show routing"}
            </.button>
            <.button id="usage-header-reset" size="sm" phx-click="reset">
              Reset filters
            </.button>
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
            <:title>{cost(@summary.total_cost)}</:title>
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

        <.disclosure_table id="usage" rows={@records} row_id={&"usage-#{&1.id}"}>
          <:col :let={r} label="When">
            <span class="whitespace-nowrap">{format_at(r.inserted_at)}</span>
          </:col>
          <:col :let={r} :if={@show_routing} label="Client">
            {r.client_key && r.client_key.name}
          </:col>
          <:col :let={r} label="Trace">
            <span class="font-mono text-xs">{short_trace(r.trace_id)}</span>
          </:col>
          <:col :let={r} :if={@show_routing} label="Requested">
            {r.request_model || r.alias_name}
          </:col>
          <:col :let={r} label="Capability">{r.capability}</:col>
          <:col :let={r} :if={@show_routing} label="Served">
            {r.deployment && r.deployment.model_name}
          </:col>
          <:col :let={r} label="Status">{status_label(r)}</:col>
          <:col :let={r} label="Tokens">{r.tokens_in}/{r.tokens_out}</:col>
          <:col :let={r} label="Latency">
            <span class="whitespace-nowrap">{latency(r.latency_ms)}</span>
          </:col>
          <:col :let={r} label="Cost">{cost(r.cost)}</:col>
          <:detail :let={r}>
            <div class="flex flex-wrap items-start justify-between gap-4">
              <dl class="grid flex-1 gap-x-8 gap-y-3 sm:grid-cols-2 lg:grid-cols-4">
                <div :for={{label, value} <- detail_fields(r)}>
                  <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                    {label}
                  </dt>
                  <dd class={[
                    "mt-0.5 text-sm text-base-content/85",
                    label == "Trace" && "font-mono text-xs"
                  ]}>
                    {value}
                  </dd>
                </div>
              </dl>
              <.button
                :if={r.trace_id}
                size="sm"
                phx-click="trace"
                phx-value-id={r.trace_id}
              >
                Filter to this trace
              </.button>
            </div>
          </:detail>
        </.disclosure_table>
      </div>
    </Layouts.app>
    """
  end

  defp apply_filters(socket, filters) do
    assign(socket,
      filters: filters,
      filter_form: to_form(filters, as: :filters),
      summary: Usage.usage_summary(filters),
      records: Usage.list_usage_records(filters, 200)
    )
  end

  defp normalize_filters(params),
    do: Map.merge(@default_filters, Map.take(params, Map.keys(@default_filters)))

  defp optionize(values), do: Enum.map(values, &{humanize(&1), to_string(&1)})

  defp humanize(value) do
    value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp detail_fields(r) do
    [
      {"Client", r.client_key && r.client_key.name},
      {"Requested", r.request_model || r.alias_name},
      {"Alias", r.alias_name},
      {"Served", r.deployment && r.deployment.model_name},
      {"Model", r.model_display_name},
      {"Version", r.model_version},
      {"Revision", r.model_revision},
      {"Finish reason", r.finish_reason},
      {"Error", r.error_code},
      {"HTTP status", r.http_status},
      {"Upstream status", r.upstream_status},
      {"Fallback", if(r.fallback_used, do: "yes", else: "no")},
      {"Tokens", "#{r.tokens_in} in / #{r.tokens_out} out"},
      {"Cost", cost(r.cost)},
      {"Trace", r.trace_id}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) or value == "" end)
  end

  defp short_trace(nil), do: "—"
  defp short_trace(trace_id), do: String.slice(trace_id, 0, 10) <> "…"

  defp cost(nil), do: "—"
  defp cost(%Decimal{} = d), do: "$" <> Decimal.to_string(Decimal.round(d, 4), :normal)

  defp latency(nil), do: "—"
  defp latency(ms), do: "#{ms} ms"

  defp status_label(%{outcome: :success}), do: "success"
  defp status_label(%{http_status: status}) when is_integer(status), do: "HTTP #{status}"
  defp status_label(%{outcome: outcome}), do: to_string(outcome)
end
