defmodule Airo.DashboardTest do
  use Airo.DataCase, async: true

  alias Airo.{Config, Dashboard, Health, Usage}

  test "summarizes gateway posture and performance" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "local-gpu",
        adapter_type: :vllm,
        base_url: "http://gpu/v1",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "qwen-dashboard",
        capabilities: [:chat]
      })

    :ok = Health.mark_deployment(deployment, provider, :up, latency_ms: 25)

    {:ok, _record} =
      Usage.record_usage(%{
        trace_id: "gt_dash",
        model_id: deployment.model_id,
        deployment_id: deployment.id,
        request_model: "qwen-dashboard",
        capability: :chat,
        outcome: :success,
        latency_ms: 42
      })

    overview = Dashboard.overview()

    assert overview.health_counts.up == 1
    assert overview.usage.total == 1
    assert Enum.sum(overview.performance.requests) == 1
    assert [%{provider: %{name: "local-gpu"}, status: :up}] = overview.provider_posture
    assert [%{model: %{upstream_model_id: "qwen-dashboard"}}] = overview.model_posture.top
    assert [%{trace_id: "gt_dash"}] = overview.recent_usage
    assert [%{status: :up}] = overview.recent_health_events
  end
end
