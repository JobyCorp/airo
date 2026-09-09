defmodule Airo.Speculative do
  @moduledoc """
  Speculative-decode efficiency, derived from a vLLM engine's raw counters.

  A slot launched with `--speculative-config` drafts several tokens per decode
  step and keeps the prefix the target model agrees with. How long that prefix
  usually is decides whether speculation is earning its keep, and the engine
  reports it only as four raw counters. This module turns them into the ratios
  a caller actually wants, so nobody divides the wrong pair.

  ## The one thing to get right

  **Every number here is cumulative since the engine started, across every
  request from every caller.** It is not attributable to your request, your
  client key, or your alias — vLLM's counters carry no such labels, and this
  build reports no per-request acceptance on the wire at all (the response's
  `metrics` and `token_ids` keys are present but null, and `usage` carries no
  `completion_tokens_details`).

  To measure one arm of a benchmark, read `drafts`, `draft_tokens` and
  `accepted_tokens` before and after it and divide the deltas. A **negative**
  delta means the slot reloaded and zeroed its counters part-way through the
  window: discard that window rather than reporting it.

  ## Absent versus zero

  `enabled: false` means the engine exposed no speculative family — the slot is
  not speculating. The numeric fields are `nil` there, never `0`, so a
  non-speculating slot can never be read as one that is speculating and
  accepting nothing. A speculating slot that has served no requests yet reports
  `enabled: true` with zero counts and `nil` ratios, for the same reason.
  """

  # Names as `Airo.Adapters.VLLM.parse_metrics/1` leaves them: the `vllm:`
  # prefix stripped, the `position` label folded into its own map.
  @drafts "spec_decode_num_drafts_total"
  @draft_tokens "spec_decode_num_draft_tokens_total"
  @accepted "spec_decode_num_accepted_tokens_total"
  @by_position "spec_decode_accepted_tokens_by_position"

  @absent %{
    enabled: false,
    drafts: nil,
    draft_tokens: nil,
    accepted_tokens: nil,
    acceptance_rate: nil,
    accepted_per_draft: nil,
    tokens_per_step: nil,
    per_position: nil,
    cumulative_since: "engine_start",
    scraped_at: nil
  }

  @type t :: %{
          enabled: boolean(),
          drafts: non_neg_integer() | nil,
          draft_tokens: non_neg_integer() | nil,
          accepted_tokens: non_neg_integer() | nil,
          acceptance_rate: float() | nil,
          accepted_per_draft: float() | nil,
          tokens_per_step: float() | nil,
          per_position: [float()] | nil,
          cumulative_since: String.t(),
          scraped_at: DateTime.t() | nil
        }

  @doc """
  The block for a slot that reports no speculative counters, or that could not
  be scraped at all. Same shape as a live reading, so a consumer never has to
  branch on which keys are present.
  """
  @spec absent(DateTime.t() | nil) :: t()
  def absent(scraped_at \\ nil), do: %{@absent | scraped_at: scraped_at}

  @doc """
  Derive the block from one model's entry in a parsed vLLM `/metrics` map.

  Returns `absent/1` unless all three scalar counters are present, so a partial
  or renamed family in a future engine build degrades to "not speculating"
  rather than to a wrong ratio.
  """
  @spec from_metrics(map() | nil, DateTime.t() | nil) :: t()
  def from_metrics(metrics, scraped_at \\ nil)

  def from_metrics(metrics, scraped_at) when is_map(metrics) do
    with drafts when is_number(drafts) <- metrics[@drafts],
         draft_tokens when is_number(draft_tokens) <- metrics[@draft_tokens],
         accepted when is_number(accepted) <- metrics[@accepted] do
      accepted_per_draft = ratio(accepted, drafts, 2)

      %{
        enabled: true,
        drafts: trunc(drafts),
        draft_tokens: trunc(draft_tokens),
        accepted_tokens: trunc(accepted),
        acceptance_rate: ratio(accepted, draft_tokens, 4),
        accepted_per_draft: accepted_per_draft,
        # One token is always produced by the target model itself; the accepted
        # draft prefix is what speculation adds on top of it.
        tokens_per_step: accepted_per_draft && Float.round(1 + accepted_per_draft, 2),
        per_position: per_position(metrics[@by_position], drafts),
        cumulative_since: "engine_start",
        scraped_at: scraped_at
      }
    else
      _ -> absent(scraped_at)
    end
  end

  def from_metrics(_metrics, scraped_at), do: absent(scraped_at)

  # The share of *drafts* whose token at this position was accepted — the decay
  # curve that says whether `num_speculative_tokens` is set too high. Positions
  # are dense from 0, so a gap in the engine's report becomes a 0.0 rather than
  # shifting every later position down a slot.
  defp per_position(positions, drafts) when is_map(positions) and map_size(positions) > 0 do
    highest = positions |> Map.keys() |> Enum.max()

    for position <- 0..highest do
      ratio(Map.get(positions, position, 0), drafts, 3) || 0.0
    end
  end

  defp per_position(_positions, _drafts), do: nil

  # A slot that has drafted nothing yet has no rate — not a rate of zero, and
  # certainly not a division by zero.
  defp ratio(_numerator, denominator, _precision) when denominator in [0, 0.0], do: nil

  defp ratio(numerator, denominator, precision),
    do: Float.round(numerator / denominator, precision)
end
