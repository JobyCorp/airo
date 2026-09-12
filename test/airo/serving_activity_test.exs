defmodule Airo.ServingActivityTest do
  # `Serving.activity/1` (S28): loaded, max concurrency, available concurrency.
  # Slot state, health, the stale flag and the in-flight Registry are all shared
  # across the node, so not async, and the tables are cleared per test.
  use Airo.DataCase, async: false

  alias Airo.Agents.SlotState
  alias Airo.Gateway.InFlight
  alias Airo.{Config, Health, Serving}

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.health_table())
    :ets.delete_all_objects(Airo.Runtime.Store.slots_table())
    :ets.delete_all_objects(Airo.Runtime.Store.hosts_table())
    :ok
  end

  defp agent do
    {:ok, agent} =
      Config.create_agent(%{
        host_id: "host-#{System.unique_integer([:positive])}",
        control_url: "http://host:4400",
        gpu: %{"available" => true, "vram_total_mb" => 24_564, "vram_used_mb" => 18_201}
      })

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

  defp model(attrs \\ %{}) do
    {:ok, model} =
      Config.create_model(
        Map.merge(
          %{
            upstream_model_id: "u-#{System.unique_integer([:positive])}",
            display_name: "m",
            status: :evaluating
          },
          attrs
        )
      )

    model
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

  # A managed slot with `model` resident and `up`, and the deployment linked to
  # that same Model — the S19 identity that makes `loaded` true.
  defp loaded_slot(opts \\ []) do
    agent = agent()
    slot = provider(%{agent_id: agent.id, name: "#{agent.host_id}:8080"})
    model = model(Keyword.get(opts, :model_attrs, %{}))
    deployment = deployment(slot, %{model_name: "m", model_id: model.id})

    SlotState.put(slot.id, %{
      resident_model: "m",
      status: Keyword.get(opts, :status, "up"),
      model_id: model.id,
      parallel: Keyword.get(opts, :parallel, 4),
      tp_rank: opts[:tp_rank],
      tp_size: opts[:tp_size]
    })

    %{agent: agent, slot: slot, model: model, deployment: deployment}
  end

  defp entry(activity, deployment_id),
    do: Enum.find(activity.deployments, &(&1.id == deployment_id))

  defp entry!(deployment_id, opts \\ []),
    do: Serving.activity(opts) |> entry(deployment_id)

  describe "loaded" do
    test "true for an up slot whose resident model is this deployment's" do
      %{deployment: d, agent: agent, slot: slot} = loaded_slot()

      assert %{loaded: true, slot_status: "up", host_id: host_id, provider: provider} =
               entry!(d.id)

      assert host_id == agent.host_id
      assert provider == slot.name
    end

    test "false with the slot's status while loading, and while down" do
      %{deployment: d} = loaded_slot(status: "loading")
      assert %{loaded: false, slot_status: "loading"} = entry!(d.id)

      %{deployment: d2} = loaded_slot(status: "down")
      assert %{loaded: false, slot_status: "down"} = entry!(d2.id)
    end

    test "false and empty when the agent has reported nothing for the slot" do
      agent = agent()
      slot = provider(%{agent_id: agent.id, name: "#{agent.host_id}:8080"})
      d = deployment(slot)

      assert %{loaded: false, slot_status: "empty", max_concurrency: nil} = entry!(d.id)
    end

    test "false and not_resident when another model is resident on the slot" do
      %{slot: slot} = loaded_slot()
      other = deployment(slot, %{model_name: "other", model_id: model().id})

      assert %{loaded: false, slot_status: "not_resident"} = entry!(other.id)
    end

    test "false and stale when the host is flagged stale, whatever the slot says" do
      %{deployment: d, agent: agent} = loaded_slot()

      :ets.insert(
        Airo.Runtime.Store.hosts_table(),
        {{:stale, agent.host_id}, %{since: 0, silent_ms: 60_000}}
      )

      assert %{loaded: false, slot_status: "stale"} = entry!(d.id)
    end

    test "a tensor-parallel peer rank never reports loaded, and has no max" do
      %{deployment: d} = loaded_slot(tp_rank: 1, tp_size: 2, parallel: 4)

      assert %{loaded: false, slot_status: "peer_rank", max_concurrency: nil} = entry!(d.id)
    end

    test "an external upstream reads probe health, with slot_status external" do
      external = provider()
      d = deployment(external)

      assert %{loaded: false, slot_status: "external", max_concurrency: nil} = entry!(d.id)

      Health.mark(d.id, :up, 12)
      assert %{loaded: true, slot_status: "external"} = entry!(d.id)
    end

    test "the topology snapshot carries loaded, slot_status and max_concurrency too" do
      %{deployment: d, agent: agent} = loaded_slot(parallel: 4)

      snapshot = Serving.snapshot()

      found =
        for host <- snapshot.hosts,
            host.host_id == agent.host_id,
            slot <- host.slots,
            entry <- slot.deployments,
            entry.id == d.id,
            do: entry

      assert [%{loaded: true, slot_status: "up", max_concurrency: 4}] = found
    end
  end

  describe "concurrency" do
    test "max comes from the slot's parallel; available equals max at idle" do
      %{deployment: d} = loaded_slot(parallel: 4)

      assert %{max_concurrency: 4, in_flight: 0, available_concurrency: 4, source: "gateway"} =
               entry!(d.id)
    end

    test "in-flight requests reduce availability, floored at zero" do
      %{deployment: d} = loaded_slot(parallel: 2)
      parent = self()

      pids =
        for _ <- 1..3 do
          spawn(fn ->
            InFlight.track(d.id)
            send(parent, :tracked)
            Process.sleep(:infinity)
          end)
        end

      for _ <- pids, do: assert_receive(:tracked)

      assert %{max_concurrency: 2, in_flight: 3, available_concurrency: 0} = entry!(d.id)

      for pid <- pids, do: Process.exit(pid, :kill)
    end

    test "available is nil when the cap is unknown, but in_flight still counts" do
      agent = agent()
      slot = provider(%{agent_id: agent.id, name: "#{agent.host_id}:8080"})
      model = model()
      d = deployment(slot, %{model_name: "m", model_id: model.id})
      SlotState.put(slot.id, %{resident_model: "m", status: "up", model_id: model.id})

      InFlight.track(d.id)

      assert %{loaded: true, max_concurrency: nil, in_flight: 1, available_concurrency: nil} =
               entry!(d.id)

      InFlight.release(d.id)
    end
  end

  describe "engine counters" do
    # A vLLM slot answering `GET /metrics`. The scrape runs in a Task, so the
    # stub has to be shared rather than owned by the test process.
    defp stub_engine(fun) do
      Req.Test.set_req_test_to_shared()
      Req.Test.stub(Airo.TestStub, fun)
    end

    defp exposition(model_name, running, waiting, kv) do
      """
      # HELP vllm:num_requests_running Number of requests in model execution batches.
      # TYPE vllm:num_requests_running gauge
      vllm:num_requests_running{engine="0",model_name="#{model_name}"} #{running}
      # TYPE vllm:num_requests_waiting gauge
      vllm:num_requests_waiting{engine="0",model_name="#{model_name}"} #{waiting}
      # TYPE vllm:kv_cache_usage_perc gauge
      vllm:kv_cache_usage_perc{engine="0",model_name="#{model_name}"} #{kv}
      """
    end

    test "nil when the option is off — no scrape is attempted" do
      # Leaving the engine unstubbed means any scrape would raise, so a nil
      # block proves nothing was asked, not that the answer was empty.
      %{deployment: d} = loaded_slot(model_attrs: %{engine: "vllm"})
      assert %{engine: nil, source: "gateway"} = entry!(d.id)
    end

    test "the engine's running count wins when it is larger, and says so" do
      %{deployment: d} = loaded_slot(parallel: 4, model_attrs: %{engine: "vllm"})
      stub_engine(fn conn -> Req.Test.text(conn, exposition("m", "3.0", "2.0", "0.25")) end)

      assert %{
               in_flight: 0,
               available_concurrency: 1,
               source: "engine",
               engine: %{running: 3, waiting: 2, kv_cache_pct: 25.0, scraped_at: %DateTime{}}
             } = entry!(d.id, engine: true)
    end

    test "the gateway count wins when the engine reports fewer" do
      %{deployment: d} = loaded_slot(parallel: 4, model_attrs: %{engine: "vllm"})
      stub_engine(fn conn -> Req.Test.text(conn, exposition("m", "0.0", "0.0", "0.0")) end)

      InFlight.track(d.id)

      assert %{in_flight: 1, available_concurrency: 3, source: "gateway", engine: %{running: 0}} =
               entry!(d.id, engine: true)

      InFlight.release(d.id)
    end

    test "an unreachable engine degrades to a nil block with the gateway arithmetic intact" do
      %{deployment: d} = loaded_slot(parallel: 4, model_attrs: %{engine: "vllm"})
      stub_engine(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert %{engine: nil, source: "gateway", available_concurrency: 4} =
               entry!(d.id, engine: true)
    end

    test "an engine serving a different model name yields nil, not zero" do
      %{deployment: d} = loaded_slot(parallel: 4, model_attrs: %{engine: "vllm"})

      stub_engine(fn conn ->
        Req.Test.text(conn, exposition("something-else", "5.0", "0.0", "0.5"))
      end)

      assert %{engine: nil, source: "gateway", available_concurrency: 4} =
               entry!(d.id, engine: true)
    end

    test "a non-vLLM slot is never scraped" do
      %{deployment: d} = loaded_slot(parallel: 1, model_attrs: %{engine: "llama_cpp"})
      assert %{engine: nil} = entry!(d.id, engine: true)
    end
  end
end
