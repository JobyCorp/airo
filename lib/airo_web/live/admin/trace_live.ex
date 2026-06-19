defmodule AiroWeb.Admin.TraceLive do
  @moduledoc """
  Unified trace timeline (DESIGN-logging-traceability.md, T4): the `usage_records`
  row(s) and every `log_events` row for one `trace_id`, interleaved by time — the
  "what happened to this request" view (predicted tier → dispatch → health →
  outcome). Reads from both contexts; `/admin/usage` is left untouched.
  """
  use AiroWeb, :live_view

  alias Airo.{Logs, Usage}
  alias AiroWeb.CompositeComponents

  @impl true
  def mount(%{"trace_id" => trace_id}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Trace #{trace_id}",
       trace_id: trace_id,
       timeline: timeline(trace_id)
     )}
  end

  defp timeline(trace_id) do
    logs = Enum.map(Logs.for_trace(trace_id), &log_entry/1)
    usage = Usage.list_usage_records(%{"trace_id" => trace_id, "range" => "all"}, 200)

    (logs ++ Enum.map(usage, &usage_entry/1))
    |> Enum.sort_by(& &1.at, NaiveDateTime)
  end

  defp log_entry(event) do
    %{
      at: event.inserted_at,
      source: "log:#{event.kind}",
      level: event.level,
      detail: event.summary
    }
  end

  defp usage_entry(record) do
    served = record.deployment && record.deployment.model_name
    fallback = if record.fallback_used, do: " (fallback)", else: ""

    %{
      at: record.inserted_at,
      source: "usage",
      level: if(record.outcome == :error, do: :error, else: :info),
      detail:
        "#{record.capability} #{record.outcome} served=#{served || "—"} " <>
          "latency=#{record.latency_ms}ms#{fallback}"
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="logs">
      <div class="mx-auto max-w-5xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle="Everything that happened to this request — prediction, dispatch, health, and outcome.">
          <:crumb navigate={~p"/admin/logs"}>Logs</:crumb>
          <:crumb>{@trace_id}</:crumb>
          <:actions>
            <.button size="sm" navigate={~p"/admin/usage"}>Usage</.button>
          </:actions>
        </CompositeComponents.page_header>

        <.card variant="bordered">
          <:title>Trace timeline</:title>

          <ol :if={@timeline != []} class="space-y-3">
            <li :for={entry <- @timeline} class="flex flex-col gap-1 sm:flex-row sm:gap-3">
              <span class="w-44 shrink-0 font-mono text-xs text-base-content/60">{entry.at}</span>
              <span class="w-28 shrink-0 text-sm font-medium">{entry.source}</span>
              <span class="text-sm text-base-content/80">{entry.detail}</span>
            </li>
          </ol>

          <p :if={@timeline == []} class="text-sm text-base-content/60">
            No events recorded for this trace.
          </p>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
