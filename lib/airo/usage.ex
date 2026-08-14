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

  # A bucket Postgres returned no rows for. Absent ≠ zero for the percentiles:
  # "no calls in this five minutes" is not "0 ms", so they stay nil.
  @empty_bucket %{
    requests: 0,
    errors: 0,
    fallbacks: 0,
    avg_latency_ms: nil,
    p50_latency_ms: nil,
    p95_latency_ms: nil
  }

  # What `aggregate/1` would return for a scope that can't match anything —
  # returned without a round trip rather than running a query we know is empty.
  @no_usage Map.merge(@empty_bucket, %{cost: Decimal.new(0)})

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

  @doc """
  Fold a `UsageRecord` query into the counts every dashboard wants — in SQL.

  This exists because the callers used to `Repo.all` the matching rows and
  reduce them in Elixir. `usage_records` grows one row per gateway call, so
  that meant materializing the whole window (85k rows / 44 MB in prod) to
  produce six numbers, and it got linearly worse forever. Postgres computes
  the same six with `count(*) FILTER` and an ordered-set aggregate and hands
  back a single row, so cost tracks the *answer* rather than the table.

  `percentile_disc`, not `percentile_cont`: it returns an actually-observed
  latency, which is what the old `Enum.at(sorted, ceil(n * p) - 1)` picked.
  Interpolating instead would silently move every published p50/p95.

  Takes any queryable so callers can scope it however they like (a filter
  set here, one model's records in `Airo.ModelShelf`).
  """
  @spec aggregate(Ecto.Queryable.t()) :: %{
          requests: non_neg_integer(),
          errors: non_neg_integer(),
          fallbacks: non_neg_integer(),
          cost: Decimal.t(),
          avg_latency_ms: integer() | nil,
          p50_latency_ms: integer() | nil,
          p95_latency_ms: integer() | nil
        }
  def aggregate(queryable) do
    queryable
    |> exclude(:preload)
    |> exclude(:order_by)
    |> exclude(:select)
    |> select([r], %{
      requests: count(r.id),
      errors: filter(count(r.id), r.outcome == :error),
      fallbacks: filter(count(r.id), r.fallback_used == true),
      cost: type(coalesce(sum(r.cost), 0), :decimal),
      avg_latency_ms: type(avg(r.latency_ms), :integer),
      p50_latency_ms: fragment("percentile_disc(0.5) WITHIN GROUP (ORDER BY ?)", r.latency_ms),
      p95_latency_ms: fragment("percentile_disc(0.95) WITHIN GROUP (ORDER BY ?)", r.latency_ms)
    })
    |> Repo.one()
  end

  @doc """
  Traffic attributed to one model: rows stamped with the model itself, plus
  rows written against any of its deployments. A row can carry both, and a
  deployment's rows count for its model even when the snapshot didn't record
  `model_id` — so the two are OR'd, matching what the shelf has always shown.

  Returns `aggregate/1`'s shape. `Airo.ModelShelf` calls this once per model
  instead of loading that model's entire usage history into structs.
  """
  @spec model_metrics(integer() | nil, [integer()]) :: map()
  def model_metrics(model_id, deployment_ids) do
    case model_scope(model_id, deployment_ids) do
      nil -> @no_usage
      scope -> aggregate(scope)
    end
  end

  @doc """
  The same traffic, split by the model version/revision it was served from —
  one row per version with its counts, latency percentiles and first/last
  sighting. Feeds the "version performance" table on the model detail page.
  """
  @spec model_version_breakdown(integer() | nil, [integer()]) :: [map()]
  def model_version_breakdown(model_id, deployment_ids) do
    case model_scope(model_id, deployment_ids) do
      nil ->
        []

      scope ->
        scope
        |> group_by([r], [r.model_version, r.model_revision])
        |> select([r], %{
          version: r.model_version,
          revision: r.model_revision,
          first_seen: min(r.inserted_at),
          last_seen: max(r.inserted_at),
          requests: count(r.id),
          errors: filter(count(r.id), r.outcome == :error),
          fallbacks: filter(count(r.id), r.fallback_used == true),
          cost: type(coalesce(sum(r.cost), 0), :decimal),
          p50_latency_ms:
            fragment("percentile_disc(0.5) WITHIN GROUP (ORDER BY ?)", r.latency_ms),
          p95_latency_ms:
            fragment("percentile_disc(0.95) WITHIN GROUP (ORDER BY ?)", r.latency_ms)
        })
        |> Repo.all()
    end
  end

  defp model_scope(nil, []), do: nil
  defp model_scope(nil, ids), do: where(UsageRecord, [r], r.deployment_id in ^ids)
  defp model_scope(model_id, []), do: where(UsageRecord, [r], r.model_id == ^model_id)

  defp model_scope(model_id, ids),
    do: where(UsageRecord, [r], r.model_id == ^model_id or r.deployment_id in ^ids)

  @doc "Summarize usage records matching UI filter params."
  def usage_summary(filters \\ %{}) do
    agg = filters |> usage_scope() |> aggregate()

    %{
      total: agg.requests,
      errors: agg.errors,
      error_rate: percent(agg.errors, agg.requests),
      fallback_count: agg.fallbacks,
      total_cost: agg.cost,
      p50_latency_ms: agg.p50_latency_ms,
      p95_latency_ms: agg.p95_latency_ms
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

    # Bucket in SQL, against the *same* `starts_at` the labels are built from.
    # The old code filtered with `filter_time_range/2` (which took its own
    # `utc_now`) and then bucketed against this one, so rows landing in the
    # microseconds between the two reads fell outside every bucket and were
    # dropped. Filtering on `starts_at` directly removes that skew, and
    # `LEAST(..., bucket_count - 1)` folds the final boundary row into the last
    # bucket exactly like the old `min(div(diff, bucket_seconds), n - 1)`.
    grouped =
      filters
      |> Map.delete("range")
      |> usage_scope()
      |> where([r], r.inserted_at >= ^starts_at)
      |> select([r], %{
        bucket:
          selected_as(
            type(
              fragment(
                "LEAST(FLOOR(EXTRACT(EPOCH FROM (? - ?)) / ?), ?)",
                r.inserted_at,
                type(^starts_at, :naive_datetime),
                ^bucket_seconds,
                ^(bucket_count - 1)
              ),
              :integer
            ),
            :bucket
          ),
        requests: count(r.id),
        errors: filter(count(r.id), r.outcome == :error),
        fallbacks: filter(count(r.id), r.fallback_used == true),
        p50_latency_ms: fragment("percentile_disc(0.5) WITHIN GROUP (ORDER BY ?)", r.latency_ms),
        p95_latency_ms: fragment("percentile_disc(0.95) WITHIN GROUP (ORDER BY ?)", r.latency_ms)
      })
      |> group_by([_r], selected_as(:bucket))
      |> Repo.all()
      |> Map.new(&{&1.bucket, &1})

    buckets =
      Enum.map(0..(bucket_count - 1), fn index ->
        bucket_start = NaiveDateTime.add(starts_at, index * bucket_seconds, :second)

        %{
          label: bucket_label(bucket_start, range),
          metrics: Map.get(grouped, index, @empty_bucket)
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

  # Filters only. Aggregates run against this — no `client_key` join and no
  # preloads, so counting doesn't drag associations back with it. The
  # `deployment` join stays because `filter_model/2` searches `d.model_name`
  # through it, and it's a 10-row table.
  defp usage_scope(filters) do
    UsageRecord
    |> join(:left, [r], d in assoc(r, :deployment))
    |> filter_outcome(filters["outcome"])
    |> filter_capability(filters["capability"])
    |> filter_client(filters["client_key_id"])
    |> filter_model(filters["model"])
    |> filter_trace(filters["trace_id"])
    |> filter_time_range(filters["range"])
  end

  # The scope plus what listing actual rows needs. Only `list_usage_records/2`
  # uses this, and it is always `limit`ed.
  defp usage_query(filters) do
    filters
    |> usage_scope()
    |> join(:left, [r, _d], k in assoc(r, :client_key))
    |> preload([r, d, k], deployment: d, client_key: k)
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
    work = fn ->
      case context |> build_attrs() |> record_usage() do
        {:ok, record} -> Airo.Logs.trace_activity(record.trace_id)
        _ -> :ok
      end
    end

    if async?() do
      Task.Supervisor.start_child(@task_supervisor, work)
    else
      work.()
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

  defp bucket_label(datetime, "7d"), do: Calendar.strftime(to_site_zone(datetime), "%m/%d")
  defp bucket_label(datetime, _range), do: Calendar.strftime(to_site_zone(datetime), "%I:%M %p")

  # Chart axis labels follow the operator zone (`/admin/settings`) like every
  # other rendered timestamp. Bucket *boundaries* stay UTC — the windows are
  # rolling, anchored at `utc_now`, so only the label needs shifting. A zone
  # the tz database can't resolve falls back to UTC rather than raising.
  defp to_site_zone(%NaiveDateTime{} = datetime) do
    utc = DateTime.from_naive!(datetime, "Etc/UTC")

    case DateTime.shift_zone(utc, Airo.Config.time_zone()) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> utc
    end
  end

  defp percent(_part, 0), do: "0.0%"

  defp percent(part, total) do
    :erlang.float_to_binary(part / total * 100, decimals: 1) <> "%"
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
