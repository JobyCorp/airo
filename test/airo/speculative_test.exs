defmodule Airo.SpeculativeTest do
  use ExUnit.Case, async: true

  alias Airo.Speculative

  # The reading taken from the speculating GLM slot on sparky:8081 on
  # 2026-09-09, in the shape `Airo.Adapters.VLLM.parse_metrics/1` produces. The
  # ratios asserted against it are the sprint's regression values.
  defp measured do
    %{
      "spec_decode_num_drafts_total" => 11_325.0,
      "spec_decode_num_draft_tokens_total" => 78_806.0,
      "spec_decode_num_accepted_tokens_total" => 29_746.0,
      "spec_decode_accepted_tokens_by_position" => %{
        0 => 8856.0,
        1 => 6387.0,
        2 => 4677.0,
        3 => 3480.0,
        4 => 2608.0,
        5 => 2073.0,
        6 => 1665.0
      }
    }
  end

  describe "from_metrics/2 on a speculating slot" do
    test "derives the measured acceptance ratios" do
      block = Speculative.from_metrics(measured())

      assert block.enabled
      assert block.acceptance_rate == 0.3775
      assert block.accepted_per_draft == 2.63
      assert block.tokens_per_step == 3.63
    end

    test "reports counts as integers, not the floats Prometheus exposes" do
      block = Speculative.from_metrics(measured())

      assert block.drafts == 11_325
      assert block.draft_tokens == 78_806
      assert block.accepted_tokens == 29_746
    end

    test "reports the per-position decay curve, ordered from position 0" do
      block = Speculative.from_metrics(measured())

      assert block.per_position == [0.782, 0.564, 0.413, 0.307, 0.23, 0.183, 0.147]
    end

    test "says the numbers are cumulative, and when they were read" do
      scraped_at = ~U[2026-09-09 15:04:05Z]
      block = Speculative.from_metrics(measured(), scraped_at)

      assert block.cumulative_since == "engine_start"
      assert block.scraped_at == scraped_at
    end

    test "pads a gap in the reported positions rather than shifting the curve" do
      metrics =
        put_in(measured()["spec_decode_accepted_tokens_by_position"], %{0 => 8856.0, 2 => 4677.0})

      assert Speculative.from_metrics(metrics).per_position == [0.782, 0.0, 0.413]
    end

    test "omits the curve entirely when the engine reports no per-position family" do
      metrics = Map.delete(measured(), "spec_decode_accepted_tokens_by_position")

      assert Speculative.from_metrics(metrics).per_position == nil
    end
  end

  describe "from_metrics/2 when the family is absent" do
    test "a non-speculating slot reads as disabled, not as zero acceptance" do
      block =
        Speculative.from_metrics(%{
          "num_requests_running" => 1.0,
          "generation_tokens_total" => 250.0
        })

      refute block.enabled
      assert block.drafts == nil
      assert block.acceptance_rate == nil
      assert block.per_position == nil
    end

    test "a partial family degrades to disabled rather than to a wrong ratio" do
      block = Speculative.from_metrics(Map.delete(measured(), "spec_decode_num_drafts_total"))

      refute block.enabled
      assert block.acceptance_rate == nil
    end

    test "an unscraped slot still carries the full shape" do
      assert Map.keys(Speculative.absent()) == Map.keys(Speculative.from_metrics(measured()))
    end

    test "nil metrics are the same as no metrics" do
      assert Speculative.from_metrics(nil) == Speculative.absent()
    end
  end

  describe "from_metrics/2 division guards" do
    test "a speculating slot that has drafted nothing has no rate, and does not raise" do
      metrics = %{
        "spec_decode_num_drafts_total" => 0.0,
        "spec_decode_num_draft_tokens_total" => 0.0,
        "spec_decode_num_accepted_tokens_total" => 0.0
      }

      block = Speculative.from_metrics(metrics)

      assert block.enabled
      assert block.drafts == 0
      assert block.acceptance_rate == nil
      assert block.accepted_per_draft == nil
      assert block.tokens_per_step == nil
    end

    test "drafts without draft tokens still yields the per-draft figure" do
      metrics = %{
        "spec_decode_num_drafts_total" => 10.0,
        "spec_decode_num_draft_tokens_total" => 0.0,
        "spec_decode_num_accepted_tokens_total" => 0.0
      }

      block = Speculative.from_metrics(metrics)

      assert block.acceptance_rate == nil
      assert block.accepted_per_draft == 0.0
      assert block.tokens_per_step == 1.0
    end
  end
end
