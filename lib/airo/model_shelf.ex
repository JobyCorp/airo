defmodule Airo.ModelShelf do
  @moduledoc """
  Read model for model management and evaluation.

  The shelf keeps routing unchanged: aliases still choose deployments. This
  module explains model posture by aggregating deployments, health, routing
  participation, and usage telemetry under durable model identities.
  """
  import Ecto.Query, warn: false

  alias Airo.Config
  alias Airo.Config.{Alias, AliasCandidate, Deployment, Model}
  alias Airo.Health
  alias Airo.Health.HealthEvent
  alias Airo.LocalModels
  alias Airo.Repo
  alias Airo.Usage.UsageRecord

  @recent_limit 25

  def list_summaries do
    Config.list_models_with_deployments()
    |> Enum.map(&summary/1)
  end

  def get_detail!(id) do
    model = Config.get_model_with_deployments!(id)
    records = usage_records(deployments: model.deployments, model_id: model.id)

    %{
      model: model,
      summary: summary(model),
      deployment_summaries: deployment_summaries(model.deployments),
      version_summaries: version_summaries(records),
      aliases: aliases_for_model(model.id),
      health_events: health_events(model.deployments),
      recent_records: recent_records(model.deployments)
    }
  end

  defp summary(%Model{} = model) do
    deployments = model.deployments || []
    records = usage_records(deployments: deployments, model_id: model.id)
    metrics = metrics(records)

    %{
      model: model,
      deployment_count: length(deployments),
      enabled_deployment_count: Enum.count(deployments, & &1.enabled),
      capabilities: capabilities(deployments),
      classes: classes(deployments),
      health: aggregate_health(deployments),
      requests: metrics.requests,
      error_rate: metrics.error_rate,
      fallback_rate: metrics.fallback_rate,
      p50_latency_ms: metrics.p50_latency_ms,
      p95_latency_ms: metrics.p95_latency_ms,
      cost: metrics.cost
    }
  end

  defp deployment_summaries(deployments) do
    Enum.map(deployments, fn deployment ->
      records = usage_records(deployments: [deployment])
      metrics = metrics(records)

      %{
        deployment: deployment,
        provider: deployment.provider,
        local_capabilities: LocalModels.capabilities(deployment.provider),
        health: Health.status(deployment.id),
        requests: metrics.requests,
        error_rate: metrics.error_rate,
        fallback_rate: metrics.fallback_rate,
        p50_latency_ms: metrics.p50_latency_ms,
        p95_latency_ms: metrics.p95_latency_ms,
        cost: metrics.cost
      }
    end)
  end

  defp usage_records(opts) do
    ids = deployment_ids(Keyword.fetch!(opts, :deployments))
    model_id = Keyword.get(opts, :model_id)

    cond do
      ids == [] and is_nil(model_id) ->
        []

      is_nil(model_id) ->
        Repo.all(from r in UsageRecord, where: r.deployment_id in ^ids)

      ids == [] ->
        Repo.all(from r in UsageRecord, where: r.model_id == ^model_id)

      true ->
        Repo.all(from r in UsageRecord, where: r.model_id == ^model_id or r.deployment_id in ^ids)
    end
  end

  defp recent_records(deployments) do
    ids = deployment_ids(deployments)

    if ids == [] do
      []
    else
      UsageRecord
      |> where([r], r.deployment_id in ^ids)
      |> order_by(desc: :inserted_at)
      |> limit(^@recent_limit)
      |> preload([:client_key, deployment: :provider])
      |> Repo.all()
    end
  end

  defp aliases_for_model(model_id) do
    AliasCandidate
    |> join(:inner, [c], a in Alias, on: a.id == c.alias_id)
    |> join(:inner, [c, a], d in Deployment, on: d.id == c.deployment_id)
    |> where([c, a, d], d.model_id == ^model_id)
    |> order_by([c, a, d], asc: a.name, asc: c.priority)
    |> preload([c, a, d], alias: a, deployment: {d, :provider})
    |> Repo.all()
  end

  defp health_events(deployments) do
    ids = deployment_ids(deployments)

    if ids == [] do
      []
    else
      HealthEvent
      |> where([e], e.deployment_id in ^ids)
      |> order_by(desc: :inserted_at)
      |> limit(^@recent_limit)
      |> preload([:provider, :deployment])
      |> Repo.all()
    end
  end

  defp metrics(records) do
    total = length(records)
    errors = Enum.count(records, &(&1.outcome == :error))
    fallbacks = Enum.count(records, & &1.fallback_used)

    %{
      requests: total,
      error_rate: percent(errors, total),
      fallback_rate: percent(fallbacks, total),
      p50_latency_ms: percentile_latency(records, 0.50),
      p95_latency_ms: percentile_latency(records, 0.95),
      cost: sum_cost(records)
    }
  end

  defp version_summaries(records) do
    records
    |> Enum.group_by(&version_key/1)
    |> Enum.map(fn {{version, revision}, grouped} ->
      metrics = metrics(grouped)
      dates = Enum.map(grouped, & &1.inserted_at)

      %{
        version: version || "Unversioned",
        revision: revision,
        first_seen: min_datetime(dates),
        last_seen: max_datetime(dates),
        requests: metrics.requests,
        error_rate: metrics.error_rate,
        fallback_rate: metrics.fallback_rate,
        p50_latency_ms: metrics.p50_latency_ms,
        p95_latency_ms: metrics.p95_latency_ms,
        cost: metrics.cost
      }
    end)
    |> Enum.sort_by(& &1.last_seen, {:desc, NaiveDateTime})
  end

  defp version_key(record), do: {record.model_version, record.model_revision}

  defp min_datetime(dates), do: Enum.min_by(dates, &NaiveDateTime.to_erl/1)
  defp max_datetime(dates), do: Enum.max_by(dates, &NaiveDateTime.to_erl/1)

  defp capabilities(deployments) do
    deployments
    |> Enum.flat_map(&(&1.capabilities || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp classes(deployments) do
    deployments
    |> Enum.map(& &1.class)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp aggregate_health([]), do: :unknown

  defp aggregate_health(deployments) do
    statuses = Enum.map(deployments, &Health.status(&1.id))

    cond do
      Enum.any?(statuses, &(&1 == :down)) -> :down
      Enum.any?(statuses, &(&1 == :up)) -> :up
      true -> :unknown
    end
  end

  defp deployment_ids(deployments), do: deployments |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)

  defp percent(_part, 0), do: "0.0%"

  defp percent(part, total) do
    :erlang.float_to_binary(part / total * 100, decimals: 1) <> "%"
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

  defp sum_cost(records) do
    Enum.reduce(records, Decimal.new(0), fn record, acc ->
      Decimal.add(acc, record.cost || Decimal.new(0))
    end)
  end
end
