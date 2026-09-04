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
      agents: agents(),
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

  # Host control agents, each summarized as a three-ring gauge: VRAM, GPU
  # utilization, and power draw. Online/offline is layered on in the web view
  # (Presence lives there); here we only shape the telemetry the agent pushed.
  defp agents do
    Config.list_agents()
    |> Repo.preload(:providers)
    |> Enum.map(&agent_gauge/1)
    |> Enum.sort_by(& &1.host_id)
  end

  defp agent_gauge(agent) do
    gpu = agent.gpu || %{}

    %{
      id: agent.id,
      host_id: agent.host_id,
      role: agent.role || :controller,
      slots: length(agent.providers),
      telemetry?: gpu_val(gpu, :available) == true,
      rings: [
        vram_ring(gpu),
        util_ring(gpu),
        power_ring(gpu)
      ]
    }
  end

  defp vram_ring(gpu) do
    used = gpu_val(gpu, :vram_used_mb)
    total = gpu_val(gpu, :vram_total_mb)

    %{
      key: "vram",
      label: "VRAM",
      tone: "primary",
      fraction: fraction(used, total),
      display: if(gb(used) && gb(total), do: "#{gb(used)} / #{gb(total)} GB", else: "—")
    }
  end

  defp util_ring(gpu) do
    pct = gpu_val(gpu, :util_pct)

    %{
      key: "util",
      label: "Compute",
      tone: "success",
      fraction: fraction(pct, 100),
      display: if(is_number(pct), do: "#{round(pct)}%", else: "—")
    }
  end

  defp power_ring(gpu) do
    draw = gpu_val(gpu, :power_draw_w)
    limit = gpu_val(gpu, :power_limit_w)

    %{
      key: "power",
      label: "Power",
      tone: "warning",
      fraction: fraction(draw, limit),
      display:
        if(is_number(draw) && is_number(limit),
          do: "#{round(draw)} / #{round(limit)} W",
          else: "—"
        )
    }
  end

  defp fraction(value, max) when is_number(value) and is_number(max) and max > 0,
    do: value |> Kernel./(max) |> min(1.0) |> max(0.0)

  defp fraction(_value, _max), do: nil

  defp gpu_val(gpu, key) when is_map(gpu), do: Map.get(gpu, key) || Map.get(gpu, to_string(key))
  defp gpu_val(_gpu, _key), do: nil

  defp gb(mb) when is_number(mb), do: Float.round(mb / 1024, 1)
  defp gb(_mb), do: nil

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
