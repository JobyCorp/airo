defmodule Airo.ModelShelfTest do
  use Airo.DataCase, async: true

  alias Airo.{Config, Health, ModelShelf, Usage}

  defp provider(name, url) do
    {:ok, provider} =
      Config.create_provider(%{
        name: name,
        adapter_type: :vllm,
        base_url: url,
        auth_kind: :none
      })

    provider
  end

  test "aggregates one model across deployments on different providers" do
    p1 = provider("mini-1", "http://mini-1/v1")
    p2 = provider("mini-2", "http://mini-2/v1")

    {:ok, d1} =
      Config.create_deployment(%{
        provider_id: p1.id,
        model_name: "qwen3.5-9b",
        capabilities: [:chat],
        class: :deep
      })

    {:ok, d2} =
      Config.create_deployment(%{
        provider_id: p2.id,
        model_name: "qwen3.5-9b",
        capabilities: [:chat],
        class: :deep
      })

    {:ok, alias_} =
      Config.create_alias(%{name: "chat-deep", capability: :chat, strategy: :priority})

    {:ok, _candidate} =
      Config.add_alias_candidate(alias_.id, %{
        deployment_id: d1.id,
        weight: 100,
        priority: 0
      })

    :ok = Health.mark_deployment(d1, p1, :up, source: :probe, latency_ms: 42)
    :ok = Health.mark_deployment(d2, p2, :down, source: :probe, reason: "http_500")

    {:ok, _} =
      Usage.record_usage(%{
        trace_id: "gt_one",
        model_id: d1.model_id,
        model_display_name: "Qwen eval",
        model_upstream_id: "qwen3.5-9b",
        model_version: "v1",
        model_revision: "r1",
        deployment_id: d1.id,
        request_model: "chat-deep",
        alias_name: "chat-deep",
        capability: :chat,
        latency_ms: 100,
        outcome: :success,
        fallback_used: false
      })

    {:ok, _} =
      Usage.record_usage(%{
        trace_id: "gt_two",
        model_id: d2.model_id,
        model_display_name: "Qwen eval",
        model_upstream_id: "qwen3.5-9b",
        model_version: "v2",
        model_revision: "r2",
        deployment_id: d2.id,
        request_model: "chat-deep",
        alias_name: "chat-deep",
        capability: :chat,
        latency_ms: 300,
        outcome: :error,
        error_code: "upstream_http_error",
        fallback_used: true
      })

    [summary] = ModelShelf.list_summaries()

    assert summary.model.upstream_model_id == "qwen3.5-9b"
    assert summary.deployment_count == 2
    assert summary.enabled_deployment_count == 2
    assert summary.health == :down
    assert summary.requests == 2
    assert summary.error_rate == "50.0%"
    assert summary.fallback_rate == "50.0%"
    assert summary.p50_latency_ms == 100
    assert summary.p95_latency_ms == 300

    detail = ModelShelf.get_detail!(summary.model.id)
    assert length(detail.deployment_summaries) == 2
    assert detail.version_summaries |> Enum.map(& &1.version) |> Enum.sort() == ["v1", "v2"]
    assert [%{alias: %{name: "chat-deep"}}] = detail.aliases

    assert detail.recent_records |> Enum.map(& &1.trace_id) |> Enum.sort() == [
             "gt_one",
             "gt_two"
           ]

    assert length(detail.health_events) == 2
  end
end
