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
    deployment_summaries = deployment_summaries(model.deployments)

    %{
      model: model,
      summary: summary(model),
      deployment_summaries: deployment_summaries,
      leading_deployment: leading_deployment(deployment_summaries),
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
    deployments
    |> Enum.map(fn deployment ->
      records = usage_records(deployments: [deployment])
      metrics = metrics(records)
      health = Health.status(deployment.id)
      score = guidance_score(deployment, health, metrics)

      %{
        deployment: deployment,
        provider: deployment.provider,
        local_capabilities: LocalModels.capabilities(deployment.provider),
        health: health,
        requests: metrics.requests,
        error_rate: metrics.error_rate,
        fallback_rate: metrics.fallback_rate,
        p50_latency_ms: metrics.p50_latency_ms,
        p95_latency_ms: metrics.p95_latency_ms,
        cost: metrics.cost,
        guidance_score: score,
        recommendation: recommendation(deployment, health, metrics, score),
        guidance_reason: guidance_reason(deployment, health, metrics)
      }
    end)
    |> Enum.sort_by(& &1.guidance_score, :desc)
  end

  defp leading_deployment([]), do: nil

  defp leading_deployment(deployment_summaries) do
    Enum.find(deployment_summaries, &(&1.recommendation in ["Lean on", "Candidate"])) ||
      List.first(deployment_summaries)
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
      errors: errors,
      fallbacks: fallbacks,
      error_ratio: ratio(errors, total),
      fallback_ratio: ratio(fallbacks, total),
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

  defp ratio(_part, 0), do: 0.0
  defp ratio(part, total), do: part / total

  defp guidance_score(deployment, health, metrics) do
    100
    |> subtract_unless(deployment.enabled, 45)
    |> subtract_unless(health == :up, health_penalty(health))
    |> Kernel.-(round(metrics.error_ratio * 100))
    |> Kernel.-(round(metrics.fallback_ratio * 50))
    |> Kernel.-(latency_penalty(metrics.p95_latency_ms))
    |> Kernel.-(traffic_penalty(metrics.requests))
    |> max(0)
  end

  defp subtract_unless(score, true, _penalty), do: score
  defp subtract_unless(score, false, penalty), do: score - penalty

  defp health_penalty(:down), do: 55
  defp health_penalty(:unknown), do: 20
  defp health_penalty(_), do: 20

  defp latency_penalty(nil), do: 0
  defp latency_penalty(ms) when ms <= 500, do: 0
  defp latency_penalty(ms) when ms <= 1_500, do: 10
  defp latency_penalty(ms) when ms <= 4_000, do: 20
  defp latency_penalty(_ms), do: 35

  defp traffic_penalty(0), do: 15
  defp traffic_penalty(requests) when requests < 5, do: 5
  defp traffic_penalty(_requests), do: 0

  defp recommendation(%{enabled: false}, _health, _metrics, _score), do: "Disabled"
  defp recommendation(_deployment, :down, _metrics, _score), do: "Avoid"
  defp recommendation(_deployment, _health, %{requests: 0}, _score), do: "Needs traffic"
  defp recommendation(_deployment, _health, _metrics, score) when score >= 85, do: "Lean on"
  defp recommendation(_deployment, _health, _metrics, score) when score >= 65, do: "Candidate"
  defp recommendation(_deployment, _health, _metrics, score) when score >= 40, do: "Watch"
  defp recommendation(_deployment, _health, _metrics, _score), do: "Avoid"

  defp guidance_reason(%{enabled: false}, _health, _metrics), do: "Routing disabled."
  defp guidance_reason(_deployment, :down, _metrics), do: "Health probe reports down."
  defp guidance_reason(_deployment, :unknown, %{requests: 0}), do: "No health or traffic yet."
  defp guidance_reason(_deployment, _health, %{requests: 0}), do: "No usage samples yet."

  defp guidance_reason(_deployment, _health, %{error_ratio: ratio}) when ratio >= 0.10,
    do: "Error rate is elevated."

  defp guidance_reason(_deployment, _health, %{fallback_ratio: ratio}) when ratio >= 0.20,
    do: "Often reached through fallback."

  defp guidance_reason(_deployment, _health, %{p95_latency_ms: ms})
       when is_integer(ms) and ms > 1_500,
       do: "p95 latency is high."

  defp guidance_reason(_deployment, _health, _metrics), do: "Healthy with usable latency."

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
