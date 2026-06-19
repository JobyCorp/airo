defmodule Airo.Logs do
  @moduledoc """
  Operational event log (DESIGN-logging-traceability.md). One `LogEvent` per
  notable gateway/health event, written **off the hot path** via
  `Airo.Usage.TaskSupervisor` so capture never blocks a request — and never raises
  into the caller (logging must not break the thing it observes).

  This is *additive*: the existing `Logger` lines still go to stdout. `/admin/logs`
  reads from here; `trace_id` correlates a request across usage ↔ logs ↔ health.
  """
  import Ecto.Query, warn: false

  alias Airo.Logs.LogEvent
  alias Airo.Repo

  @task_supervisor Airo.Usage.TaskSupervisor
  @pubsub Airo.PubSub

  @doc "Subscribe the caller to the live log feed (`/admin/logs`)."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, "logs")

  @doc "Subscribe the caller to live activity for one `trace_id` (log events + usage)."
  def subscribe_trace(trace_id) when is_binary(trace_id),
    do: Phoenix.PubSub.subscribe(@pubsub, trace_topic(trace_id))

  @doc """
  Broadcast non-log activity for a trace's live timeline (e.g. a `usage_records`
  write), so an open trace view refreshes. No-op without a trace id.
  """
  def trace_activity(trace_id) when is_binary(trace_id),
    do: Phoenix.PubSub.broadcast(@pubsub, trace_topic(trace_id), {:trace_activity, :usage})

  def trace_activity(_), do: :ok

  defp trace_topic(trace_id), do: "trace:" <> trace_id

  @doc """
  Record an operational event. Returns `:ok` immediately; the insert happens in a
  task (async in dev/prod, synchronous in test so the SQL sandbox is available).
  Fire-and-forget — a bad write is dropped, never propagated. On success it
  broadcasts to the live feed and the event's trace topic.
  """
  @spec record(map()) :: :ok
  def record(attrs) when is_map(attrs) do
    if async?() do
      Task.Supervisor.start_child(@task_supervisor, fn -> insert(attrs) end)
    else
      insert(attrs)
    end

    :ok
  end

  defp insert(attrs) do
    case %LogEvent{} |> LogEvent.changeset(attrs) |> Repo.insert() do
      {:ok, event} = ok ->
        publish(event)
        ok

      other ->
        other
    end
  rescue
    _ -> :error
  end

  defp publish(%LogEvent{} = event) do
    Phoenix.PubSub.broadcast(@pubsub, "logs", {:log_event, event})

    if event.trace_id,
      do: Phoenix.PubSub.broadcast(@pubsub, trace_topic(event.trace_id), {:trace_activity, event})

    :ok
  end

  defp async?, do: Application.get_env(:airo, __MODULE__, [])[:async] != false

  @doc "Recent events matching UI filter params, newest first."
  @spec list(map(), pos_integer()) :: [LogEvent.t()]
  def list(filters \\ %{}, limit \\ 100) when is_map(filters) do
    filters
    |> query()
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "All events for one `trace_id`, oldest-first (timeline order)."
  @spec for_trace(String.t()) :: [LogEvent.t()]
  def for_trace(trace_id) when is_binary(trace_id) do
    LogEvent
    |> where([e], e.trace_id == ^trace_id)
    |> order_by(asc: :inserted_at, asc: :id)
    |> preload([:provider, :deployment])
    |> Repo.all()
  end

  @doc "Counts for the filtered set (for the stat strip)."
  def summary(filters \\ %{}) do
    events = filters |> query() |> Repo.all()

    %{
      total: length(events),
      warnings: Enum.count(events, &(&1.level == :warning)),
      errors: Enum.count(events, &(&1.level == :error))
    }
  end

  def kind_options, do: LogEvent.kinds()
  def level_options, do: LogEvent.levels()

  ## Internal

  defp query(filters) do
    LogEvent
    |> preload([:provider, :deployment])
    |> filter_kind(filters["kind"])
    |> filter_level(filters["level"])
    |> filter_alias(filters["alias"])
    |> filter_predicted_class(filters["predicted_class"])
    |> filter_trace(filters["trace_id"])
    |> filter_time_range(filters["range"])
  end

  defp filter_kind(query, kind) when is_binary(kind) and kind != "",
    do: where(query, [e], e.kind == ^kind)

  defp filter_kind(query, _), do: query

  defp filter_level(query, level) when is_binary(level) and level != "",
    do: where(query, [e], e.level == ^level)

  defp filter_level(query, _), do: query

  defp filter_alias(query, name) when is_binary(name) and name != "",
    do: where(query, [e], ilike(e.alias_name, ^"%#{name}%"))

  defp filter_alias(query, _), do: query

  # `predicted_class` lives in the jsonb `data` of `:route_prediction` events.
  defp filter_predicted_class(query, class) when is_binary(class) and class != "",
    do: where(query, [e], fragment("?->>'predicted_class' = ?", e.data, ^class))

  defp filter_predicted_class(query, _), do: query

  defp filter_trace(query, trace) when is_binary(trace) and trace != "",
    do: where(query, [e], ilike(e.trace_id, ^"%#{trace}%"))

  defp filter_trace(query, _), do: query

  defp filter_time_range(query, "1h"), do: since(query, -3_600)
  defp filter_time_range(query, "24h"), do: since(query, -86_400)
  defp filter_time_range(query, "7d"), do: since(query, -604_800)
  defp filter_time_range(query, _), do: query

  defp since(query, seconds) do
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(seconds, :second)
    where(query, [e], e.inserted_at >= ^cutoff)
  end
end
