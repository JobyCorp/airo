defmodule Airo.ServingClusterTest do
  @moduledoc """
  Two-node tensor-parallel serving: a model too large for one host runs as one
  logical load across several slots, only rank 0 of which serves the API.

  Modelled on the real DSpark pair — sparky (rank 0) and sparky2 (rank 1) running
  DeepSeek V4 Flash at TP=2.
  """
  use Airo.DataCase, async: false

  # These assert health *classification*, not how many failures it takes (S24).
  setup do
    Airo.Test.Health.set_failure_threshold(1)
    :ok
  end

  alias Airo.Agents.{Ingest, SlotState}
  alias Airo.{Config, Health, Serving}

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.health_table())
    :ets.delete_all_objects(Airo.Runtime.Store.slots_table())
    :ok
  end

  @model "fraserprice/DeepSeek-V4-Flash-DSpark:fp8"
  @cluster "dep-7f3a"

  defp agent(host_id) do
    {:ok, agent} =
      Config.create_agent(%{
        host_id: host_id,
        control_url: "http://#{host_id}:4400",
        gpu: %{"available" => true, "vram_total_mb" => 124_546, "vram_used_mb" => 118_415}
      })

    agent
  end

  # Register a slot the way the agent channel does, then push its state.
  defp push(host_id, port, attrs) do
    slot = Map.merge(%{"port" => port, "base_url" => "http://#{host_id}:#{port}/v1"}, attrs)
    :ok = Ingest.register(host_id, %{"agent" => %{}, "slots" => [slot]})
    Config.get_provider_by_name("#{host_id}:#{port}")
  end

  defp rank(host_id, port, tp_rank, overrides \\ %{}) do
    push(
      host_id,
      port,
      Map.merge(
        %{
          "resident_model" => @model,
          "status" => "up",
          "deployment_id" => @cluster,
          "tp_rank" => tp_rank,
          "tp_size" => 2,
          "ctx" => 32_768
        },
        overrides
      )
    )
  end

  # A two-node cluster with the head's deployment bound, as an operator would.
  defp two_node_cluster do
    agent("sparky")
    agent("sparky2")

    head = rank("sparky", 8081, 0)

    {:ok, deployment} =
      Config.create_deployment(%{provider_id: head.id, model_name: @model, capabilities: [:chat]})

    head = rank("sparky", 8081, 0)
    peer = rank("sparky2", 8081, 1)

    %{head: head, peer: peer, deployment: Config.get_deployment!(deployment.id)}
  end

  defp slot_for(snapshot, host_id) do
    snapshot.hosts |> Enum.find(&(&1.host_id == host_id)) |> Map.fetch!(:slots) |> hd()
  end

  describe "ingest" do
    test "both ranks report a slot carrying the shared id and their own rank" do
      two_node_cluster()

      head = SlotState.get(Config.get_provider_by_name("sparky:8081").id)
      peer = SlotState.get(Config.get_provider_by_name("sparky2:8081").id)

      assert head.cluster_id == @cluster
      assert head.tp_rank == 0
      assert head.tp_size == 2

      assert peer.cluster_id == @cluster
      assert peer.tp_rank == 1
      assert peer.tp_size == 2

      # The peer carries the same model — it just owns no Model row of its own.
      assert peer.resident_model == @model
    end

    test "a peer does not mint a Model of its own" do
      two_node_cluster()

      # Provenance keys models as <host>_<model>_<port>, so an unguarded peer
      # would reconcile a second canonical Model for one logical load. Assert on
      # the host-qualified key: the head's must exist, the peer's must not.
      keys = Config.list_models() |> Enum.map(& &1.upstream_model_id)

      assert "sparky_#{@model}_8081" in keys
      refute "sparky2_#{@model}_8081" in keys
    end

    test "a peer never gets a deployment bound to it" do
      two_node_cluster()

      peer = Config.get_provider_by_name("sparky2:8081")

      assert Config.list_deployments() |> Enum.filter(&(&1.provider_id == peer.id)) == []
    end

    test "a deployment hand-bound to a peer is forced down rather than left routable" do
      two_node_cluster()
      peer = Config.get_provider_by_name("sparky2:8081")

      {:ok, stray} =
        Config.create_deployment(%{
          provider_id: peer.id,
          model_name: @model,
          capabilities: [:chat]
        })

      Health.mark(stray.id, :up)
      rank("sparky2", 8081, 1)

      assert Health.status(stray.id) == :down
    end

    test "the head is up while every rank is up" do
      %{deployment: deployment} = two_node_cluster()

      assert Health.status(deployment.id) == :up
    end
  end

  describe "cluster health propagation" do
    test "a peer going down takes the head's deployment down with it" do
      %{deployment: deployment} = two_node_cluster()
      assert Health.status(deployment.id) == :up

      rank("sparky2", 8081, 1, %{"status" => "down", "reason" => "engine exited"})

      # The head's own slot still reads `up` — nothing about it changed — but its
      # engine cannot serve without the peer's shard.
      assert SlotState.get(Config.get_provider_by_name("sparky:8081").id).status == :up
      assert Health.status(deployment.id) == :down
    end

    test "a loading peer degrades the head to unknown rather than down" do
      %{deployment: deployment} = two_node_cluster()

      rank("sparky2", 8081, 1, %{"status" => "loading"})

      assert Health.status(deployment.id) == :unknown
    end

    test "the head recovers when the peer comes back" do
      %{deployment: deployment} = two_node_cluster()

      rank("sparky2", 8081, 1, %{"status" => "down"})
      assert Health.status(deployment.id) == :down

      rank("sparky2", 8081, 1)
      assert Health.status(deployment.id) == :up
    end

    test "losing the peer's host entirely takes the head down" do
      %{deployment: deployment} = two_node_cluster()
      assert Health.status(deployment.id) == :up

      # A silent rank leaves no slot state at all, so absence — not a `down`
      # status — is what the head has to notice.
      Ingest.host_down("sparky2")

      assert Health.status(deployment.id) == :down
    end

    test "a head whose peer has not registered yet is not treated as serving" do
      agent("sparky")
      head = rank("sparky", 8081, 0)

      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: head.id,
          model_name: @model,
          capabilities: [:chat]
        })

      rank("sparky", 8081, 0)

      assert Health.status(deployment.id) == :down
    end

    test "a single-node load is unaffected by cluster logic" do
      agent("jobycorp")
      slot = push("jobycorp", 8081, %{"resident_model" => "qwen.gguf", "status" => "up"})

      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: slot.id,
          model_name: "qwen.gguf",
          capabilities: [:chat]
        })

      push("jobycorp", 8081, %{"resident_model" => "qwen.gguf", "status" => "up"})

      assert Health.status(deployment.id) == :up
      assert SlotState.get(slot.id).cluster_id == nil
    end
  end

  describe "snapshot" do
    test "each rank's slot carries its cluster identity" do
      two_node_cluster()
      snapshot = Serving.snapshot()

      head = slot_for(snapshot, "sparky")
      peer = slot_for(snapshot, "sparky2")

      assert head.resident.cluster == %{id: @cluster, tp_rank: 0, tp_size: 2}
      assert peer.resident.cluster == %{id: @cluster, tp_rank: 1, tp_size: 2}
      assert head.resident.model == @model
      assert peer.resident.model == @model
    end

    test "only the head advertises that it serves the API" do
      two_node_cluster()
      snapshot = Serving.snapshot()

      assert slot_for(snapshot, "sparky").serves_api
      refute slot_for(snapshot, "sparky2").serves_api
    end

    test "joins the ranks into one logical cluster entry" do
      two_node_cluster()

      assert [cluster] = Serving.snapshot().clusters

      assert cluster.id == @cluster
      assert cluster.model == @model
      assert cluster.tp_size == 2
      assert cluster.complete
      assert cluster.serving

      assert [
               %{host_id: "sparky", tp_rank: 0, serves_api: true, status: :up},
               %{host_id: "sparky2", tp_rank: 1, serves_api: false, status: :up}
             ] = cluster.members
    end

    test "a cluster missing a rank is neither complete nor serving" do
      two_node_cluster()
      Ingest.host_down("sparky2")

      assert [cluster] = Serving.snapshot().clusters

      refute cluster.complete
      refute cluster.serving
      assert length(cluster.members) == 1
    end

    test "a cluster with a down rank is complete but not serving" do
      two_node_cluster()
      rank("sparky2", 8081, 1, %{"status" => "down"})

      assert [cluster] = Serving.snapshot().clusters

      assert cluster.complete
      refute cluster.serving
    end

    test "a single-node load produces no cluster entry" do
      agent("jobycorp")
      push("jobycorp", 8081, %{"resident_model" => "qwen.gguf", "status" => "up"})

      snapshot = Serving.snapshot()

      assert snapshot.clusters == []
      assert slot_for(snapshot, "jobycorp").resident.cluster == nil
      assert slot_for(snapshot, "jobycorp").serves_api
    end

    test "passes through gpu utilisation and power telemetry" do
      {:ok, _} =
        Config.create_agent(%{
          host_id: "sparky",
          control_url: "http://sparky:4400",
          gpu: %{
            "available" => true,
            "vram_total_mb" => 124_546,
            "vram_used_mb" => 118_415,
            "util_pct" => 87.5,
            "power_draw_w" => 11.87,
            "mem_source" => "unified"
          }
        })

      gpu = Serving.snapshot().hosts |> Enum.find(&(&1.host_id == "sparky")) |> Map.fetch!(:gpu)

      assert gpu.util_pct == 87.5
      assert gpu.power_draw_w == 11.87
      assert gpu.mem_source == "unified"
      assert gpu.power_limit_w == nil
    end
  end

  describe "capacity" do
    test "charges each host only its shard of the weights" do
      two_node_cluster()

      # 200 GB of weights across two hosts is 100 GB each, not 200 GB each.
      size_bytes = 200 * 1024 * 1024 * 1024
      full = Airo.Agents.Capacity.footprint_mb(size_bytes)
      shard = Airo.Agents.Capacity.footprint_mb(Airo.Agents.Capacity.shard_bytes(size_bytes, 2))

      assert_in_delta shard, full / 2, 0.5
    end
  end
end
