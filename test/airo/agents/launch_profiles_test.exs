defmodule Airo.Agents.LaunchProfilesTest do
  use Airo.DataCase, async: true

  alias Airo.Agents

  @model "fraserprice/DeepSeek-V4-Flash-Abliterated-DSpark:fp8"
  @profile %{
    "nnodes" => 2,
    "tensor_parallel_size" => 2,
    "ctx" => 1_048_576,
    "image" => "ghcr.io/anemll/dspark-vllm-gx10:0.1.1",
    "entrypoint" => "vllm",
    "cmd_prefix" => "",
    "container_env" => %{"NCCL_IB_GID_INDEX" => "5"},
    "extra_argv" => ["--kv-cache-dtype", "nvfp4_ds_mla"]
  }

  test "launch_profile/1 returns nil for a model with no saved recipe" do
    assert Agents.launch_profile("nobody/never-loaded") == nil
  end

  test "save + read back round-trips the profile map" do
    assert {:ok, _} = Agents.save_launch_profile(@model, @profile)
    assert Agents.launch_profile(@model) == @profile
  end

  test "saving again replaces the profile (upsert by model name)" do
    assert {:ok, _} = Agents.save_launch_profile(@model, @profile)
    assert {:ok, _} = Agents.save_launch_profile(@model, %{"ctx" => 32_768})
    assert Agents.launch_profile(@model) == %{"ctx" => 32_768}
  end

  test "launch_profiles/1 maps only the model ids that have a recipe" do
    assert {:ok, _} = Agents.save_launch_profile(@model, @profile)

    assert Agents.launch_profiles([@model, "other/model"]) == %{@model => @profile}
    assert Agents.launch_profiles([]) == %{}
  end
end
