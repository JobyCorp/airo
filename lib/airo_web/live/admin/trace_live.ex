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
    if connected?(socket), do: Logs.subscribe_trace(trace_id)

    {:ok,
     assign(socket,
       page_title: "Trace #{trace_id}",
       trace_id: trace_id,
       streaming: connected?(socket),
       timeline: timeline(trace_id)
     )}
  end

  # Live: a new log event or usage write for this trace re-stitches the timeline.
  @impl true
  def handle_info({:trace_activity, _}, socket) do
    {:noreply, assign(socket, timeline: timeline(socket.assigns.trace_id))}
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
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle="Everything that happened to this request — prediction, dispatch, health, and outcome.">
          <:crumb navigate={~p"/admin/logs"}>Logs</:crumb>
          <:crumb>{@trace_id}</:crumb>
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
            <.button size="sm" navigate={~p"/admin/usage"}>Usage</.button>
          </:actions>
        </CompositeComponents.page_header>

        <.card variant="bordered">
          <:title>Trace timeline</:title>

          <ol :if={@timeline != []} class="relative space-y-6 border-l border-base-content/15 py-1">
            <li :for={entry <- @timeline} class="relative ml-6">
              <span class={[
                "absolute -left-[1.875rem] top-1 size-3 rounded-full ring-4 ring-base-100",
                dot_class(entry.level)
              ]} />
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono text-xs text-base-content/45">{format_at(entry.at)}</span>
                <CompositeComponents.tag tone={source_tone(entry)}>
                  {entry.source}
                </CompositeComponents.tag>
              </div>
              <p class="mt-1 text-sm text-base-content/80">{entry.detail}</p>
            </li>
          </ol>

          <CompositeComponents.empty_state
            :if={@timeline == []}
            icon="hero-magnifying-glass"
            title="No events for this trace"
          >
            Nothing was recorded under this trace id.
          </CompositeComponents.empty_state>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp dot_class(:error), do: "bg-error"
  defp dot_class(:warning), do: "bg-warning"
  defp dot_class(_), do: "bg-base-content/30"

  defp source_tone(%{level: :error}), do: "error"
  defp source_tone(%{level: :warning}), do: "warning"
  defp source_tone(%{source: "usage"}), do: "primary"
  defp source_tone(_), do: "neutral"

  defp format_at(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%b %d  %H:%M:%S")
  defp format_at(other), do: to_string(other)
end
