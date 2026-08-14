defmodule Airo.ModelShelf do
  @moduledoc """
  Read model for model management and evaluation.

  The shelf keeps routing unchanged: aliases still choose deployments. This
  module explains model posture by aggregating deployments, health, routing
  participation, and usage telemetry under durable model identities.
  """
  import Ecto.Query, warn: false

  alias Airo.Agents.{Provenance, SlotState}
  alias Airo.Config
  alias Airo.Config.{Alias, AliasCandidate, Deployment, Model}
  alias Airo.Health
  alias Airo.Health.HealthEvent
  alias Airo.LocalModels
  alias Airo.Repo
  alias Airo.Usage
  alias Airo.Usage.UsageRecord

  @recent_limit 25

  def list_summaries do
    resident = resident_identities()

    Config.list_models_with_deployments()
    |> Enum.map(&summary(&1, resident))
  end

  def get_detail!(id) do
    model = Config.get_model_with_deployments!(id)
    scope = [deployments: model.deployments, model_id: model.id]
    deployment_summaries = deployment_summaries(model.deployments)

    %{
      model: model,
      summary: summary(model, resident_identities()),
      deployment_summaries: deployment_summaries,
      leading_deployment: leading_deployment(deployment_summaries),
      version_summaries: version_summaries(scope),
      aliases: aliases_for_model(model.id),
      health_events: health_events(model.deployments),
      recent_records: recent_records(model.deployments)
    }
  end

  defp summary(%Model{} = model, resident) do
    deployments = model.deployments || []
    metrics = metrics(usage_metrics(deployments: deployments, model_id: model.id))

    %{
      model: model,
      deployment_count: length(deployments),
      enabled_deployment_count: Enum.count(deployments, & &1.enabled),
      resident?: MapSet.member?(resident, model.upstream_model_id),
      capabilities: capabilities(deployments),
      classes: classes(deployments),
      health: aggregate_health(deployments),
      requests: metrics.requests,
      error_rate: metrics.error_rate,
      fallback_rate: metrics.fallback_rate,
      avg_latency_ms: metrics.avg_latency_ms,
      p50_latency_ms: metrics.p50_latency_ms,
      p95_latency_ms: metrics.p95_latency_ms,
      cost: metrics.cost
    }
  end

  @doc """
  Whether a model is currently resident in a live agent slot. Such a model has no
  `deployments` row by design — its runtime state lives in `Airo.Agents.SlotState`
  — so anything that keys off deployment count ("orphaned", deletable) must consult
  this too, or it will mistake a slot-served model for an abandoned catalog entry.
  """
  def resident?(%Model{upstream_model_id: id}), do: resident?(id)

  def resident?(upstream_model_id) when is_binary(upstream_model_id),
    do: MapSet.member?(resident_identities(), upstream_model_id)

  # Canonical ids of models resident in a live agent slot. A slot records its
  # resident model in `SlotState` (ETS) and writes no `deployments` row, so a
  # served-by-slot model looks deployment-less. Rebuild the ids provenance minted
  # for them (`<host_id>_<resident_id>_<port>`) so the shelf can tell "served by a
  # slot" apart from "truly orphaned".
  defp resident_identities do
    Config.list_agents()
    |> Repo.preload(:providers)
    |> Enum.flat_map(fn agent ->
      for provider <- agent.providers,
          state = SlotState.get(provider.id),
          resident = state[:resident_model],
          is_binary(resident) and resident != "",
          port = slot_port(provider.name),
          not is_nil(port) do
        Provenance.identity(agent.host_id, resident, port)
      end
    end)
    |> MapSet.new()
  end

  # The serving port is the suffix of a slot provider's "<host_id>:<port>" name —
  # the same `port` provenance folds into the model's canonical id.
  defp slot_port(name) do
    case name |> to_string() |> String.split(":") |> List.last() |> Integer.parse() do
      {port, _} -> port
      :error -> nil
    end
  end

  defp deployment_summaries(deployments) do
    deployments
    |> Enum.map(fn deployment ->
      metrics = metrics(usage_metrics(deployments: [deployment]))
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

  # Counts, not rows. This used to `Repo.all` every usage record the model had
  # ever produced — for each of the ~10 models, on every dashboard render and
  # every 10s refresh. One model alone was 35k rows in prod, and the cost grew
  # with the table forever. `Airo.Usage` does the same arithmetic in SQL and
  # returns one row.
  defp usage_metrics(opts) do
    opts
    |> Keyword.get(:model_id)
    |> Usage.model_metrics(deployment_ids(Keyword.fetch!(opts, :deployments)))
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

  # Presentation shape over the raw counts `Airo.Usage` hands back: the ratios
  # feed `guidance_score/3`, the percent strings feed the tables.
  defp metrics(%{requests: total, errors: errors, fallbacks: fallbacks} = agg) do
    %{
      requests: total,
      errors: errors,
      fallbacks: fallbacks,
      error_ratio: ratio(errors, total),
      fallback_ratio: ratio(fallbacks, total),
      error_rate: percent(errors, total),
      fallback_rate: percent(fallbacks, total),
      avg_latency_ms: agg.avg_latency_ms,
      p50_latency_ms: agg.p50_latency_ms,
      p95_latency_ms: agg.p95_latency_ms,
      cost: agg.cost
    }
  end

  defp version_summaries(opts) do
    opts
    |> Keyword.get(:model_id)
    |> Usage.model_version_breakdown(deployment_ids(Keyword.fetch!(opts, :deployments)))
    |> Enum.map(fn row ->
      %{
        version: row.version || "Unversioned",
        revision: row.revision,
        first_seen: row.first_seen,
        last_seen: row.last_seen,
        requests: row.requests,
        error_rate: percent(row.errors, row.requests),
        fallback_rate: percent(row.fallbacks, row.requests),
        p50_latency_ms: row.p50_latency_ms,
        p95_latency_ms: row.p95_latency_ms,
        cost: row.cost
      }
    end)
    |> Enum.sort_by(& &1.last_seen, {:desc, NaiveDateTime})
  end

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
end
