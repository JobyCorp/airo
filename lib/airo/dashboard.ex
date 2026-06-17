defmodule Airo.Dashboard do
  @moduledoc """
  Read model for the root operational dashboard.

  The dashboard is intentionally a thin composition layer over existing
  contexts. It should summarize gateway posture and point operators to the
  deeper admin surfaces without becoming another configuration plane.
  """

  alias Airo.{Config, Health, ModelShelf, Repo, Usage}

  @usage_filters %{"range" => "24h"}
  @recent_limit 8
  @top_model_limit 5

  def overview do
    providers = Config.list_providers() |> Repo.preload(:deployments)
    deployments = Config.list_deployments() |> Repo.preload([:provider, :model])
    models = ModelShelf.list_summaries()

    %{
      providers: providers,
      deployments: deployments,
      models: models,
      aliases: Config.list_aliases(),
      client_keys: Config.list_client_keys(),
      usage: Usage.usage_summary(@usage_filters),
      performance: Usage.performance_series(@usage_filters),
      health_counts: health_counts(deployments),
      provider_posture: provider_posture(providers),
      model_posture: model_posture(models),
      recent_usage: Usage.list_usage_records(@usage_filters, @recent_limit),
      recent_health_events: Health.list_events(@recent_limit)
    }
  end

  defp health_counts(deployments) do
    counts =
      deployments
      |> Enum.map(&Health.status(&1.id))
      |> Enum.frequencies()

    %{
      up: Map.get(counts, :up, 0),
      down: Map.get(counts, :down, 0),
      unknown: Map.get(counts, :unknown, 0)
    }
  end

  defp provider_posture(providers) do
    providers
    |> Enum.map(fn provider ->
      deployments = provider.deployments || []

      %{
        provider: provider,
        status: aggregate_health(deployments),
        deployment_count: length(deployments),
        enabled_deployment_count: Enum.count(deployments, & &1.enabled)
      }
    end)
    |> Enum.sort_by(&provider_sort_key/1)
  end

  defp model_posture(models) do
    %{
      total: length(models),
      healthy: Enum.count(models, &(&1.health == :up)),
      watch: watch_models(models),
      needs_traffic: needs_traffic(models),
      top: top_models(models)
    }
  end

  defp top_models(models) do
    models
    |> Enum.sort_by(fn summary ->
      {summary.health != :up, -(summary.requests || 0), summary.p95_latency_ms || 999_999}
    end)
    |> Enum.take(@top_model_limit)
  end

  defp watch_models(models) do
    models
    |> Enum.filter(fn summary ->
      summary.health == :down or summary.error_rate != "0.0%" or
        slow?(summary.p95_latency_ms)
    end)
    |> Enum.sort_by(fn summary -> {summary.health == :up, summary.p95_latency_ms || 0} end, :desc)
    |> Enum.take(@top_model_limit)
  end

  defp needs_traffic(models) do
    models
    |> Enum.filter(&((&1.requests || 0) == 0))
    |> Enum.take(@top_model_limit)
  end

  defp slow?(nil), do: false
  defp slow?(latency_ms), do: latency_ms >= 5_000

  defp aggregate_health([]), do: :unknown

  defp aggregate_health(deployments) do
    statuses = Enum.map(deployments, &Health.status(&1.id))

    cond do
      Enum.any?(statuses, &(&1 == :down)) -> :down
      Enum.any?(statuses, &(&1 == :up)) -> :up
      true -> :unknown
    end
  end

  defp provider_sort_key(%{status: :down}), do: {0, 0}
  defp provider_sort_key(%{status: :unknown}), do: {1, 0}
  defp provider_sort_key(%{status: :up, deployment_count: count}), do: {2, -count}
end
