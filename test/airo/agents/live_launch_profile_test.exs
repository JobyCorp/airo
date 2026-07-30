defmodule Airo.Agents.LiveLaunchProfileTest do
  @moduledoc """
  Recording the launch recipe a slot is *actually running*.

  The config modal only knows about loads it initiated. A model brought up any
  other way — a hand-POSTed `/load` (`airo_agent`'s `deploy/payloads/*.json`),
  an agent-side restore after a restart — used to leave nothing behind, so the
  next load out of the UI fell back to a bare default: a modest context, single
  node, none of the image or engine env a hand-tuned launch needs.

  Modelled on the real DSpark pair: sparky (rank 0) + sparky2 (rank 1).
  """
  use Airo.DataCase, async: false

  alias Airo.Agents
  alias Airo.Agents.Ingest
  alias Airo.Config
  alias Airo.Config.LaunchProfile

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.health_table())
    :ets.delete_all_objects(Airo.Runtime.Store.slots_table())
    :ok
  end

  @model "fraserprice/DeepSeek-V4-Flash-DSpark:fp8"
  @cluster "dep-7f3a"

  # The effective profile the agent reports once up — defaults resolved, so it
  # round-trips back through `/load` verbatim.
  @effective %{
    "ctx" => 1_048_576,
    "nnodes" => 2,
    "tensor_parallel_size" => 2,
    "parallel" => 6,
    "image" => "ghcr.io/anemll/dspark-vllm-gx10:0.1.1",
    "entrypoint" => "vllm",
    "kv_cache_dtype" => "nvfp4_ds_mla",
    "gpu_memory_utilization" => 0.845,
    "container_env" => %{"NCCL_IB_ADDR_FAMILY" => "AF_INET", "NCCL_NET" => "IB"},
    "extra_argv" => ["--block-size", "256", "--enable-prefix-caching"]
  }

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

  defp rank(host_id, port, tp_rank, overrides) do
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
          "ctx" => 1_048_576,
          "profile" => @effective
        },
        overrides
      )
    )
  end

  describe "recording what a slot reports" do
    test "an up head's effective profile becomes the model's launch recipe" do
      agent("sparky")
      rank("sparky", 8081, 0, %{})

      assert Agents.launch_profile(@model) == @effective
    end

    test "a single-host slot loaded out of band is recorded too" do
      agent("pve-extract")

      push("pve-extract", 8081, %{
        "resident_model" => "unsloth/Qwen3.6-9B-GGUF:Q6_K",
        "status" => "up",
        "ctx" => 131_072,
        "profile" => %{"ctx" => 131_072, "parallel" => 2, "entrypoint" => "llama-server"}
      })

      assert Agents.launch_profile("unsloth/Qwen3.6-9B-GGUF:Q6_K") == %{
               "ctx" => 131_072,
               "parallel" => 2,
               "entrypoint" => "llama-server"
             }
    end

    test "the recipe outlives the slot — that is the whole point" do
      agent("sparky")
      rank("sparky", 8081, 0, %{})

      Ingest.host_down("sparky")

      # Slot state is gone (it self-heals on re-register); the recipe is not, so
      # the next load starts from 1M/TP-2 rather than a guess.
      assert Agents.launch_profile(@model) == @effective
    end
  end

  describe "what is not recorded" do
    test "a loading slot — the agent is echoing the requested profile, not the resolved one" do
      agent("sparky")
      rank("sparky", 8081, 0, %{"status" => "loading"})

      assert Agents.launch_profile(@model) == nil
    end

    test "a failed load is no recipe" do
      agent("sparky")
      rank("sparky", 8081, 0, %{"status" => "failed", "reason" => "CUDA OOM"})

      assert Agents.launch_profile(@model) == nil
    end

    test "a peer rank — the head's body is what reproduces the cluster" do
      agent("sparky2")
      rank("sparky2", 8081, 1, %{"profile" => %{"ctx" => 1_048_576, "rank" => 1}})

      assert Agents.launch_profile(@model) == nil
    end

    test "a peer cannot clobber the head's recipe" do
      agent("sparky")
      agent("sparky2")

      rank("sparky", 8081, 0, %{})
      rank("sparky2", 8081, 1, %{"profile" => %{"ctx" => 1_048_576, "rank" => 1}})

      assert Agents.launch_profile(@model) == @effective
    end

    test "a push carrying no profile leaves the recipe alone" do
      agent("sparky")
      rank("sparky", 8081, 0, %{})

      # `profile` rides only the heartbeat register; a transition push omits it.
      rank("sparky", 8081, 0, %{"profile" => nil})

      assert Agents.launch_profile(@model) == @effective
    end

    test "an empty slot with no resident model records nothing" do
      agent("sparky")
      push("sparky", 8081, %{"status" => "empty"})

      assert Repo.aggregate(LaunchProfile, :count) == 0
    end
  end

  describe "churn" do
    test "an unchanged profile is not re-written on every heartbeat" do
      agent("sparky")
      rank("sparky", 8081, 0, %{})

      stamp = Repo.get_by!(LaunchProfile, model_name: @model).updated_at

      rank("sparky", 8081, 0, %{})
      rank("sparky", 8081, 0, %{})

      assert Repo.get_by!(LaunchProfile, model_name: @model).updated_at == stamp
      assert Repo.aggregate(LaunchProfile, :count) == 1
    end

    test "a genuinely changed profile does replace the recipe" do
      agent("sparky")
      rank("sparky", 8081, 0, %{})

      smaller = Map.put(@effective, "ctx", 262_144)
      rank("sparky", 8081, 0, %{"profile" => smaller})

      assert Agents.launch_profile(@model) == smaller
      assert Repo.aggregate(LaunchProfile, :count) == 1
    end
  end
end
