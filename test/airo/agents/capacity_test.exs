defmodule Airo.Agents.CapacityTest do
  use ExUnit.Case, async: true

  alias Airo.Agents.Capacity

  # 10 GiB in bytes; footprint = 10240 MB * 1.2 = 12288.0
  @ten_gib 10 * 1024 * 1024 * 1024

  defp gpu(used_mb, total_mb \\ 32_607.0),
    do: %{"available" => true, "vram_used_mb" => used_mb, "vram_total_mb" => total_mb}

  describe "footprint_mb/1" do
    test "applies the 1.2 overhead margin to the weights size" do
      assert Capacity.footprint_mb(@ten_gib) == 12_288.0
    end

    test "unknown size is nil" do
      assert Capacity.footprint_mb(nil) == nil
    end
  end

  describe "headroom/1" do
    test "computes free from total - used" do
      assert Capacity.headroom(gpu(2_000.0, 32_607.0)) ==
               %{total_mb: 32_607.0, used_mb: 2_000.0, free_mb: 30_607.0}
    end

    test "is :unavailable when telemetry is absent or unavailable" do
      assert Capacity.headroom(%{"available" => false}) == :unavailable
      assert Capacity.headroom(%{}) == :unavailable
      assert Capacity.headroom(nil) == :unavailable
    end

    test "tolerates atom keys" do
      assert %{free_mb: 8_000.0} =
               Capacity.headroom(%{
                 available: true,
                 vram_total_mb: 10_000.0,
                 vram_used_mb: 2_000.0
               })
    end
  end

  describe "assess/3" do
    test "fits when the footprint is within free space" do
      assert %{footprint_mb: 12_288.0, free_mb: 30_607.0, fits?: true} =
               Capacity.assess(@ten_gib, gpu(2_000.0))
    end

    test "does not fit when the footprint exceeds free space" do
      # only 5 GB free, model needs ~12 GB
      assert %{fits?: false} = Capacity.assess(@ten_gib, gpu(27_607.0))
    end

    test "a swap adds the outgoing model's footprint back to free" do
      # 27607 used → ~5 GB free; without reclaim the 10 GiB model won't fit...
      assert %{fits?: false} = Capacity.assess(@ten_gib, gpu(27_607.0))
      # ...but swapping out another 10 GiB model frees ~12 GB, so it fits.
      assert %{fits?: true} =
               Capacity.assess(@ten_gib, gpu(27_607.0), reclaim_bytes: @ten_gib)
    end

    test "fits? is :unknown with no telemetry" do
      assert %{footprint_mb: 12_288.0, free_mb: nil, fits?: :unknown} =
               Capacity.assess(@ten_gib, %{"available" => false})
    end

    test "fits? is :unknown when the model size is unknown" do
      assert %{footprint_mb: nil, fits?: :unknown} = Capacity.assess(nil, gpu(2_000.0))
    end
  end
end
