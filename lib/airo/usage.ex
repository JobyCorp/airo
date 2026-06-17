defmodule Airo.Usage do
  @moduledoc """
  Usage + cost attribution (DESIGN §10). One `UsageRecord` per gateway call,
  written **off the response path** via `Airo.Usage.TaskSupervisor` so recording
  never blocks the client. Cost is derived from the served deployment's pricing
  (`price_input`/`price_output`, per 1k tokens).
  """
  import Ecto.Query, warn: false

  alias Airo.Repo
  alias Airo.Config.Model
  alias Airo.Usage.UsageRecord

  @task_supervisor Airo.Usage.TaskSupervisor

  @doc "List recent usage records, newest first."
  def list_usage_records(limit \\ 100) do
    list_usage_records(%{}, limit)
  end

  @doc "List recent usage records matching UI filter params, newest first."
  def list_usage_records(filters, limit) when is_map(filters) do
    filters
    |> usage_query()
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Summarize usage records matching UI filter params."
  def usage_summary(filters \\ %{}) do
    records = filters |> usage_query() |> Repo.all()

    total = length(records)
    errors = Enum.count(records, &(&1.outcome == :error))
    fallbacks = Enum.count(records, & &1.fallback_used)

    %{
      total: total,
      errors: errors,
      error_rate: percent(errors, total),
      fallback_count: fallbacks,
      total_cost: sum_cost(records),
      p50_latency_ms: percentile_latency(records, 0.50),
      p95_latency_ms: percentile_latency(records, 0.95)
    }
  end

  @doc """
  Bucket usage records into chart-ready performance series.

  Supported ranges mirror the usage UI: `"1h"`, `"24h"`, and `"7d"`.
  The result intentionally contains plain lists so LiveViews can JSON-encode it
  directly for chart hooks without leaking Ecto structs into the client.
  """
  def performance_series(filters \\ %{}) do
    range = Map.get(filters, "range", "24h")
    {window_seconds, bucket_seconds, bucket_count} = bucket_config(range)

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    starts_at = NaiveDateTime.add(now, -window_seconds, :second)

    records =
      filters
      |> Map.put("range", range)
      |> usage_query()
      |> Repo.all()

    grouped =
      records
      |> Enum.group_by(&bucket_index(&1, starts_at, bucket_seconds, bucket_count))
      |> Map.drop([nil])

    buckets =
      Enum.map(0..(bucket_count - 1), fn index ->
        bucket_start = NaiveDateTime.add(starts_at, index * bucket_seconds, :second)
        bucket_records = Map.get(grouped, index, [])

        %{
          label: bucket_label(bucket_start, range),
          records: bucket_records,
          metrics: bucket_metrics(bucket_records)
        }
      end)

    %{
      categories: Enum.map(buckets, & &1.label),
      requests: Enum.map(buckets, & &1.metrics.requests),
      errors: Enum.map(buckets, & &1.metrics.errors),
      fallbacks: Enum.map(buckets, & &1.metrics.fallbacks),
      p50_latency_ms: Enum.map(buckets, & &1.metrics.p50_latency_ms),
      p95_latency_ms: Enum.map(buckets, & &1.metrics.p95_latency_ms)
    }
  end

  @doc "Total cost across the recorded usage (Decimal)."
  def total_cost do
    Repo.one(from r in UsageRecord, select: coalesce(sum(r.cost), 0))
  end

  def client_options do
    from(k in Airo.Config.ClientKey, order_by: [asc: k.name], select: {k.name, k.id})
    |> Repo.all()
  end

  def capability_options, do: UsageRecord.capabilities()
  def outcome_options, do: UsageRecord.outcomes()

  defp usage_query(filters) do
    UsageRecord
    |> join(:left, [r], d in assoc(r, :deployment))
    |> join(:left, [r, d], k in assoc(r, :client_key))
    |> preload([r, d, k], deployment: d, client_key: k)
    |> filter_outcome(filters["outcome"])
    |> filter_capability(filters["capability"])
    |> filter_client(filters["client_key_id"])
    |> filter_model(filters["model"])
    |> filter_trace(filters["trace_id"])
    |> filter_time_range(filters["range"])
  end

  @doc "Persist a single usage record synchronously."
  def record_usage(attrs) do
    %UsageRecord{} |> UsageRecord.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Record usage asynchronously from a call context map. Returns immediately;
  the record is built (tokens, finish reason, cost) and inserted in a task.

  Context keys: `:client_key`, `:served` (a `Airo.Gateway.attempt` or nil),
  `:alias_name`, `:capability`, `:response` (OpenAI body or nil), `:latency_ms`,
  `:outcome`, `:fallback_used`.
  """
  def record_async(context) do
    if async?() do
      Task.Supervisor.start_child(@task_supervisor, fn ->
        context |> build_attrs() |> record_usage()
      end)
    else
      context |> build_attrs() |> record_usage()
    end

    :ok
  end

  # Synchronous in test (so the SQL sandbox connection is available); async in
  # dev/prod so recording never blocks the response.
  defp async?, do: Application.get_env(:airo, __MODULE__, [])[:async] != false

  @doc """
  Build `UsageRecord` attrs from a call context — extracts token counts and
  finish reason from the OpenAI response and computes cost from the served
  deployment's pricing. Exposed for testing; normally called via `record_async/1`.
  """
  def build_attrs(context) do
    {tokens_in, tokens_out} = tokens(context[:response])
    deployment = context[:served] && context[:served].deployment
    model_snapshot = model_snapshot(deployment)

    %{
      client_key_id: context[:client_key] && context[:client_key].id,
      trace_id: context[:trace_id],
      request_model: context[:request_model] || context[:alias_name],
      model_id: model_snapshot[:id],
      model_display_name: model_snapshot[:display_name],
      model_upstream_id: model_snapshot[:upstream_model_id],
      model_version: model_snapshot[:version],
      model_revision: model_snapshot[:revision],
      deployment_id: deployment && deployment.id,
      alias_name: context[:alias_name],
      capability: context[:capability],
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      latency_ms: context[:latency_ms],
      outcome: context[:outcome] || :success,
      error_code: context[:error_code],
      http_status: context[:http_status],
      upstream_status: context[:upstream_status],
      finish_reason: finish_reason(context[:response]),
      fallback_used: context[:fallback_used] || false,
      cost: cost(deployment, tokens_in, tokens_out)
    }
  end

  ## Internal

  defp filter_outcome(query, outcome) when outcome in ["success", "error", "timeout"] do
    where(query, [r], r.outcome == ^outcome)
  end

  defp filter_outcome(query, _), do: query

  defp filter_capability(query, capability) when is_binary(capability) and capability != "" do
    where(query, [r], r.capability == ^capability)
  end

  defp filter_capability(query, _), do: query

  defp filter_client(query, id) when is_binary(id) and id != "" do
    case Integer.parse(id) do
      {id, ""} -> where(query, [r], r.client_key_id == ^id)
      _ -> query
    end
  end

  defp filter_client(query, _), do: query

  defp filter_model(query, model) when is_binary(model) and model != "" do
    pattern = "%#{model}%"

    where(
      query,
      [r, d],
      ilike(r.request_model, ^pattern) or ilike(r.alias_name, ^pattern) or
        ilike(d.model_name, ^pattern)
    )
  end

  defp filter_model(query, _), do: query

  defp filter_trace(query, trace_id) when is_binary(trace_id) and trace_id != "" do
    where(query, [r], ilike(r.trace_id, ^"%#{trace_id}%"))
  end

  defp filter_trace(query, _), do: query

  defp filter_time_range(query, "1h"), do: since(query, -3_600)
  defp filter_time_range(query, "24h"), do: since(query, -86_400)
  defp filter_time_range(query, "7d"), do: since(query, -604_800)
  defp filter_time_range(query, _), do: query

  defp model_snapshot(nil), do: %{}

  defp model_snapshot(%{model: %Model{} = model}), do: model_snapshot(model)

  defp model_snapshot(%{model_id: model_id}) when not is_nil(model_id) do
    case Repo.get(Model, model_id) do
      nil -> %{}
      model -> model_snapshot(model)
    end
  end

  defp model_snapshot(%Model{} = model) do
    %{
      id: model.id,
      display_name: model.display_name,
      upstream_model_id: model.upstream_model_id,
      version: model.version,
      revision: model.revision
    }
  end

  defp model_snapshot(_deployment), do: %{}

  defp since(query, seconds) do
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(seconds, :second)
    where(query, [r], r.inserted_at >= ^cutoff)
  end

  defp bucket_config("1h"), do: {3_600, 300, 12}
  defp bucket_config("7d"), do: {604_800, 86_400, 7}
  defp bucket_config(_range), do: {86_400, 3_600, 24}

  defp bucket_index(%{inserted_at: inserted_at}, starts_at, bucket_seconds, bucket_count) do
    diff = NaiveDateTime.diff(inserted_at, starts_at, :second)

    cond do
      diff < 0 -> nil
      diff > bucket_seconds * bucket_count -> nil
      true -> min(div(diff, bucket_seconds), bucket_count - 1)
    end
  end

  defp bucket_label(datetime, "7d"), do: Calendar.strftime(datetime, "%m/%d")
  defp bucket_label(datetime, _range), do: Calendar.strftime(datetime, "%H:%M")

  defp bucket_metrics(records) do
    %{
      requests: length(records),
      errors: Enum.count(records, &(&1.outcome == :error)),
      fallbacks: Enum.count(records, & &1.fallback_used),
      p50_latency_ms: percentile_latency(records, 0.50),
      p95_latency_ms: percentile_latency(records, 0.95)
    }
  end

  defp percent(_part, 0), do: "0.0%"

  defp percent(part, total) do
    :erlang.float_to_binary(part / total * 100, decimals: 1) <> "%"
  end

  defp sum_cost(records) do
    Enum.reduce(records, Decimal.new(0), fn record, acc ->
      Decimal.add(acc, record.cost || Decimal.new(0))
    end)
  end

  defp percentile_latency(records, percentile) do
    latencies =
      records
      |> Enum.map(& &1.latency_ms)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    case latencies do
      [] ->
        nil

      list ->
        index = ceil(length(list) * percentile) - 1
        Enum.at(list, max(index, 0))
    end
  end

  defp tokens(%{"usage" => usage}) when is_map(usage),
    do: {usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0}

  defp tokens(_response), do: {0, 0}

  defp finish_reason(%{"choices" => [%{"finish_reason" => reason} | _]}), do: reason
  defp finish_reason(_response), do: nil

  defp cost(nil, _tokens_in, _tokens_out), do: nil
  defp cost(%{price_input: nil, price_output: nil}, _tokens_in, _tokens_out), do: nil

  defp cost(%{price_input: price_in, price_output: price_out}, tokens_in, tokens_out),
    do: Decimal.add(per_1k(price_in, tokens_in), per_1k(price_out, tokens_out))

  defp per_1k(nil, _tokens), do: Decimal.new(0)

  defp per_1k(price, tokens),
    do: Decimal.mult(price, Decimal.div(Decimal.new(tokens || 0), 1000))
end
