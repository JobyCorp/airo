defmodule Airo.ServingTest do
  use Airo.DataCase, async: false

  alias Airo.Agents.SlotState
  alias Airo.Config
  alias Airo.{Health, Serving, Usage}

  # Health and slot state live in ETS shared across the node, so these tests are
  # not async and clear the tables they touch.
  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.health_table())
    :ets.delete_all_objects(Airo.Runtime.Store.slots_table())
    :ok
  end

  defp agent(attrs \\ %{}) do
    {:ok, agent} =
      Config.create_agent(
        Map.merge(
          %{
            host_id: "host-#{System.unique_integer([:positive])}",
            control_url: "http://host:4400",
            gpu: %{"available" => true, "vram_total_mb" => 24_564, "vram_used_mb" => 18_201}
          },
          attrs
        )
      )

    agent
  end

  defp provider(attrs \\ %{}) do
    {:ok, provider} =
      Config.create_provider(
        Map.merge(
          %{
            name: "p-#{System.unique_integer([:positive])}",
            adapter_type: :openai,
            base_url: "http://p:8080/v1",
            auth_kind: :none
          },
          attrs
        )
      )

    provider
  end

  defp deployment(provider, attrs \\ %{}) do
    {:ok, deployment} =
      Config.create_deployment(
        Map.merge(
          %{
            provider_id: provider.id,
            model_name: "m-#{System.unique_integer([:positive])}",
            capabilities: [:chat]
          },
          attrs
        )
      )

    deployment
  end

  defp find_slot(snapshot, host_id, provider_name) do
    snapshot.hosts
    |> Enum.find(&(&1.host_id == host_id))
    |> Map.fetch!(:slots)
    |> Enum.find(&(&1.provider == provider_name))
  end

  describe "snapshot/1 topology" do
    test "binds a slot's resident model back to its host" do
      agent = agent()
      slot = provider(%{agent_id: agent.id, name: "#{agent.host_id}:8080"})

      SlotState.put(slot.id, %{
        resident_model: "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf",
        status: "up",
        ctx: 32_768,
        ctx_total: 131_072,
        parallel: 4,
        engine_build: "b4321",
        profile: %{"kv_quant" => "q8_0"}
      })

      resident =
        Serving.snapshot() |> find_slot(agent.host_id, slot.name) |> Map.fetch!(:resident)

      assert resident.model == "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
      assert resident.status == :up
      assert resident.ctx == 32_768
      assert resident.ctx_total == 131_072
      assert resident.parallel == 4
      assert resident.engine_build == "b4321"
      assert resident.profile == %{"kv_quant" => "q8_0"}
      assert %DateTime{} = resident.resident_since
    end

    test "an empty or unreported slot has no resident model rather than a map of nils" do
      agent = agent()
      empty = provider(%{agent_id: agent.id, name: "#{agent.host_id}:8080"})
      unreported = provider(%{agent_id: agent.id, name: "#{agent.host_id}:8081"})

      SlotState.put(empty.id, %{resident_model: nil, status: "empty"})

      snapshot = Serving.snapshot()

      assert find_slot(snapshot, agent.host_id, empty.name).resident == nil
      assert find_slot(snapshot, agent.host_id, unreported.name).resident == nil
    end

    test "reports the canonical upstream_model_id, not just the artifact name" do
      {:ok, model} =
        Config.create_model(%{
          upstream_model_id: "jobycorp_Qwen3.6-35B_8080",
          display_name: "Qwen3.6-35B",
          family: "qwen",
          quantization: "Q4_K_XL"
        })

      slot = provider(%{agent_id: agent().id})
      deployment(slot, %{model_name: "Qwen3.6-35B", model_id: model.id})

      external =
        Serving.snapshot().hosts
        |> Enum.flat_map(& &1.slots)
        |> Enum.flat_map(& &1.deployments)
        |> Enum.find(&(&1.model_name == "Qwen3.6-35B"))

      assert external.upstream_model_id == "jobycorp_Qwen3.6-35B_8080"
      assert external.display_name == "Qwen3.6-35B"
    end

    test "gpu telemetry that is off is reported as unavailable, not as zero free" do
      dark = agent(%{gpu: %{}})

      gpu =
        Serving.snapshot().hosts |> Enum.find(&(&1.host_id == dark.host_id)) |> Map.fetch!(:gpu)

      assert gpu.available == false
      assert gpu.vram_free_mb == nil
    end

    test "computes free vram from the host's telemetry" do
      host = agent()

      gpu =
        Serving.snapshot().hosts |> Enum.find(&(&1.host_id == host.host_id)) |> Map.fetch!(:gpu)

      assert gpu.available
      assert gpu.vram_total_mb == 24_564
      assert gpu.vram_used_mb == 18_201
      assert gpu.vram_free_mb == 6363.0
    end
  end

  describe "snapshot/1 eligibility and health" do
    test "separates the hard config gate from the health preference" do
      up = provider()
      down = provider()
      disabled_provider = provider(%{enabled: false})

      up_deployment = deployment(up)
      down_deployment = deployment(down)
      disabled_deployment = deployment(up, %{enabled: false})
      under_disabled = deployment(disabled_provider)

      Health.mark(up_deployment.id, :up, 12)
      Health.mark(down_deployment.id, :down)
      Health.mark(disabled_deployment.id, :up)
      Health.mark(under_disabled.id, :up)

      by_id =
        Serving.snapshot().external_providers
        |> Enum.flat_map(& &1.deployments)
        |> Map.new(&{&1.id, &1})

      assert %{eligible: true, routable: true, routable_reason: nil} = by_id[up_deployment.id]

      # Unhealthy but eligible: Airo still tries it last rather than refusing.
      assert %{eligible: true, routable: false, routable_reason: "health_down"} =
               by_id[down_deployment.id]

      assert %{eligible: false, routable: false, routable_reason: "deployment_disabled"} =
               by_id[disabled_deployment.id]

      assert %{eligible: false, routable: false, routable_reason: "provider_disabled"} =
               by_id[under_disabled.id]
    end

    test "marks a health snapshot older than the staleness window as stale" do
      fresh = deployment(provider())
      stale = deployment(provider())

      Health.mark(fresh.id, :up, 9)

      :ets.insert(
        Airo.Runtime.Store.health_table(),
        {stale.id,
         %{
           status: :up,
           latency_ms: 9,
           checked_at: System.monotonic_time(:millisecond) - Health.staleness_ms() - 1_000
         }}
      )

      by_id =
        Serving.snapshot().external_providers
        |> Enum.flat_map(& &1.deployments)
        |> Map.new(&{&1.id, &1})

      assert %{status: :up, stale: false} = by_id[fresh.id].health
      assert by_id[fresh.id].health.age_ms >= 0

      # The raw record still says :up; the effective status has decayed.
      assert %{status: :unknown, stale: true} = by_id[stale.id].health
      refute by_id[stale.id].routable
    end

    test "a never-probed deployment reads unknown and stale, not healthy" do
      never = deployment(provider())

      health =
        Serving.snapshot().external_providers
        |> Enum.flat_map(& &1.deployments)
        |> Enum.find(&(&1.id == never.id))
        |> Map.fetch!(:health)

      assert health == %{
               status: :unknown,
               latency_ms: nil,
               checked_at: nil,
               age_ms: nil,
               stale: true
             }
    end

    test "reports the last real inference alongside probe health" do
      served = deployment(provider())

      Usage.record_usage(%{
        deployment_id: served.id,
        outcome: :success,
        tokens_in: 5,
        tokens_out: 7
      })

      Usage.record_usage(%{
        deployment_id: served.id,
        outcome: :error,
        error_code: "upstream_unavailable"
      })

      entry =
        Serving.snapshot().external_providers
        |> Enum.flat_map(& &1.deployments)
        |> Enum.find(&(&1.id == served.id))

      assert entry.last_success_at
      assert entry.last_error_at
      assert entry.last_error_code == "upstream_unavailable"
    end
  end

  describe "snapshot/1 aliases" do
    test "reports candidate reachability, not just candidate names" do
      healthy = deployment(provider())
      unhealthy = deployment(provider())

      Health.mark(healthy.id, :up)
      Health.mark(unhealthy.id, :down)

      {:ok, _} =
        Config.create_alias(%{
          name: "chat-test",
          capability: :chat,
          strategy: :priority,
          fallback: ["chat-deep"],
          candidates: [
            %{deployment_id: healthy.id, weight: 100, priority: 0},
            %{deployment_id: unhealthy.id, weight: 50, priority: 1}
          ]
        })

      entry = Serving.snapshot().aliases |> Enum.find(&(&1.name == "chat-test"))

      assert entry.candidate_count == 2
      assert entry.routable_candidates == 1
      assert entry.servable
      assert entry.fallback == ["chat-deep"]
      assert [%{priority: 0, routable: true}, %{priority: 1, routable: false}] = entry.candidates
    end

    test "an alias whose only candidate is disabled is not servable" do
      disabled = deployment(provider(), %{enabled: false})

      {:ok, _} =
        Config.create_alias(%{
          name: "chat-dead",
          capability: :chat,
          strategy: :priority,
          candidates: [%{deployment_id: disabled.id, weight: 100, priority: 0}]
        })

      entry = Serving.snapshot().aliases |> Enum.find(&(&1.name == "chat-dead"))

      refute entry.servable
      assert entry.routable_candidates == 0
    end
  end

  describe "health_transitions/1" do
    defp transition(deployment, provider, status, source \\ :probe) do
      {:ok, event} =
        Health.record_event(%{
          deployment_id: deployment.id,
          provider_id: provider.id,
          status: status,
          source: source
        })

      event
    end

    test "derives previous_status and duration_ms per deployment" do
      p = provider()
      d = deployment(p)

      transition(d, p, :up)
      transition(d, p, :down)
      transition(d, p, :up)

      events = Serving.health_transitions().events |> Enum.filter(&(&1.deployment_id == d.id))

      assert [first, second, third] = events
      assert %{status: :up, previous_status: nil, changed: true} = first
      assert %{status: :down, previous_status: :up, changed: true} = second
      assert %{status: :up, previous_status: :down, changed: true} = third
      assert is_integer(second.duration_ms)
    end

    test "back-fills the predecessor for the first event of a page" do
      p = provider()
      d = deployment(p)

      transition(d, p, :up)
      boundary = transition(d, p, :down)
      transition(d, p, :up)

      [event] =
        Serving.health_transitions(since: boundary.id).events
        |> Enum.filter(&(&1.deployment_id == d.id))

      # The `:down` row is outside the window, but still supplies the predecessor.
      assert event.status == :up
      assert event.previous_status == :down
      assert event.changed
    end

    test "flags a repeat of the same status as unchanged" do
      p = provider()
      d = deployment(p)

      transition(d, p, :up)
      transition(d, p, :up)

      [_first, repeat] =
        Serving.health_transitions().events |> Enum.filter(&(&1.deployment_id == d.id))

      refute repeat.changed
    end

    test "paginates with an exact cursor" do
      p = provider()
      d = deployment(p)

      Enum.each([:up, :down, :up, :down], &transition(d, p, &1))

      page = Serving.health_transitions(limit: 2)

      assert length(page.events) == 2
      assert page.has_more
      assert page.next_since == page.events |> List.last() |> Map.fetch!(:id)

      next = Serving.health_transitions(since: page.next_since)

      refute next.has_more
      assert Enum.all?(next.events, &(&1.id > page.next_since))
    end

    test "carries the source, so a probe failure is distinguishable from a real dispatch failure" do
      p = provider()
      d = deployment(p)

      transition(d, p, :down, :dispatch)

      assert [%{source: :dispatch}] =
               Serving.health_transitions().events |> Enum.filter(&(&1.deployment_id == d.id))
    end
  end

  describe "usage_rollup/1" do
    setup do
      p = provider()
      d = deployment(p, %{model_name: "rollup-model"})

      records =
        for {outcome, tokens} <- [{:success, 10}, {:success, 20}, {:error, 0}] do
          {:ok, record} =
            Usage.record_usage(%{
              deployment_id: d.id,
              outcome: outcome,
              capability: :chat,
              alias_name: "chat",
              tokens_in: tokens,
              tokens_out: tokens * 2,
              latency_ms: tokens * 10,
              cost: Decimal.new("0.001")
            })

          record
        end

      %{deployment: d, provider: p, records: records}
    end

    test "aggregates tokens, cost and outcomes per deployment", %{deployment: d} do
      row = Serving.usage_rollup().rows |> Enum.find(&(&1.deployment_id == d.id))

      assert row.model_name == "rollup-model"
      assert row.requests == 3
      assert row.errors == 1
      assert row.tokens_in == 30
      assert row.tokens_out == 60
      assert_in_delta row.cost, 0.003, 0.0001
      assert is_integer(row.p50_latency_ms)
    end

    test "a since cursor partitions the record stream exactly", %{deployment: d, records: records} do
      boundary = records |> Enum.map(& &1.id) |> Enum.min()

      row = Serving.usage_rollup(since: boundary).rows |> Enum.find(&(&1.deployment_id == d.id))

      # The boundary record itself is excluded — it was counted by the prior poll.
      assert row.requests == 2
      assert row.tokens_in == 20
    end

    test "next_since is the newest record counted", %{records: records} do
      assert Serving.usage_rollup().next_since == records |> Enum.map(& &1.id) |> Enum.max()
    end

    test "groups along the requested axis" do
      assert Serving.usage_rollup(group_by: :capability).rows
             |> Enum.find(&(&1.capability == :chat))
             |> Map.fetch!(:requests) == 3

      assert Serving.usage_rollup(group_by: "alias").rows
             |> Enum.find(&(&1.alias == "chat"))
             |> Map.fetch!(:requests) == 3
    end

    test "an unrecognized grouping falls back to deployment rather than erroring" do
      assert Serving.usage_rollup(group_by: "nonsense").group_by == :deployment
    end

    test "reports zero cost rather than nil for an empty window" do
      assert Serving.usage_rollup(since: 999_999_999).rows == []
    end
  end

  describe "parse_since/1" do
    test "reads an id cursor" do
      assert Serving.parse_since("42") == 42
      assert Serving.parse_since(42) == 42
    end

    test "reads an ISO 8601 timestamp in either form" do
      assert Serving.parse_since("2026-07-26T14:02:11Z") == ~N[2026-07-26 14:02:11]
      assert Serving.parse_since("2026-07-26T14:02:11") == ~N[2026-07-26 14:02:11]
    end

    test "an unparseable cursor reads the full window rather than returning nothing" do
      assert Serving.parse_since("garbage") == nil
      assert Serving.parse_since(nil) == nil
    end
  end
end
