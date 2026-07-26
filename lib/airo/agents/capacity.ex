defmodule Airo.Agents.Capacity do
  @moduledoc """
  Memory-fit estimation for loading a model onto a host slot (S18, see
  [DESIGN-agent-placement.md](../../../docs/design/DESIGN-agent-placement.md)).

  Pure arithmetic over data S17 already surfaces — the model's `size_bytes`
  (inventory) and the host's live `vram_total_mb`/`vram_used_mb` (`agent.gpu`).
  It produces an **advisory** estimate, never a gate: weights are only a floor,
  so the footprint carries a flat `@margin` for KV-cache / context / runtime
  overhead, and live `used_mb` (which already drives the VRAM meter) is the real
  signal once a model is resident.
  """

  # Weights are the floor; pad for KV-cache/context/runtime overhead.
  @margin 1.2
  @bytes_per_mb 1_048_576

  @type headroom :: %{total_mb: float(), used_mb: float(), free_mb: float()} | :unavailable
  @type assessment :: %{
          footprint_mb: float() | nil,
          free_mb: float() | nil,
          fits?: boolean() | :unknown
        }

  @doc "Estimated resident footprint (MB) of a model, or `nil` if size is unknown."
  @spec footprint_mb(non_neg_integer() | nil) :: float() | nil
  def footprint_mb(size_bytes) when is_integer(size_bytes) and size_bytes >= 0 do
    Float.round(size_bytes / @bytes_per_mb * @margin, 1)
  end

  def footprint_mb(_size_bytes), do: nil

  @doc """
  Per-host share of a model's `size_bytes` under `nnodes`-way multi-node tensor
  parallelism — each rank holds 1/n of the weights, so fit is judged against one
  host's share. `nnodes` ≤ 1 (or an unknown size) passes through unchanged.
  """
  @spec shard_bytes(non_neg_integer() | nil, term()) :: non_neg_integer() | nil
  def shard_bytes(size_bytes, nnodes)
      when is_integer(size_bytes) and is_integer(nnodes) and nnodes > 1,
      do: div(size_bytes, nnodes)

  def shard_bytes(size_bytes, _nnodes), do: size_bytes

  @doc """
  Host memory headroom from a GPU telemetry map (string- or atom-keyed), or
  `:unavailable` when the host reports no usable telemetry.
  """
  @spec headroom(map() | nil) :: headroom()
  def headroom(gpu) when is_map(gpu) do
    total = num(gpu, :vram_total_mb)
    used = num(gpu, :vram_used_mb)

    if fetch(gpu, :available) == true and is_number(total) and is_number(used) do
      # `/ 1` coerces to float: an agent reporting whole megabytes sends integers,
      # and `Float.round/2` raises on an integer.
      %{total_mb: total, used_mb: used, free_mb: Float.round((total - used) / 1, 1)}
    else
      :unavailable
    end
  end

  def headroom(_gpu), do: :unavailable

  @doc """
  Assess loading a model of `size_bytes` onto a host with the given `gpu`
  telemetry.

  `:reclaim_bytes` (a swap into an occupied slot) is added back to free space,
  since the outgoing model unloads first. With no telemetry or unknown size,
  `fits?` is `:unknown` — advisory degrades, it never guesses a failure.
  """
  @spec assess(non_neg_integer() | nil, map() | nil, keyword()) :: assessment()
  def assess(size_bytes, gpu, opts \\ []) do
    footprint = footprint_mb(size_bytes)

    case headroom(gpu) do
      %{free_mb: free} ->
        reclaim = footprint_mb(opts[:reclaim_bytes]) || 0.0
        effective_free = Float.round(free + reclaim, 1)

        %{
          footprint_mb: footprint,
          free_mb: free,
          fits?: if(is_number(footprint), do: footprint <= effective_free, else: :unknown)
        }

      :unavailable ->
        %{footprint_mb: footprint, free_mb: nil, fits?: :unknown}
    end
  end

  defp num(gpu, key) do
    case fetch(gpu, key) do
      n when is_number(n) -> n
      _ -> nil
    end
  end

  # GPU maps arrive string-keyed over the channel; tolerate atoms too.
  defp fetch(gpu, key), do: Map.get(gpu, key) || Map.get(gpu, to_string(key))

  # --- context-aware VRAM validation (S21, see DESIGN-vram-validation.md) ---

  # Validate against this fraction of total VRAM; over-commit segfaults the engine.
  @vram_margin 0.95

  @type validation :: %{
          projected_mb: float() | nil,
          budget_mb: float() | nil,
          fits?: boolean() | :cold | :unknown
        }

  @doc """
  Measured VRAM cost per KV token, calibrated from the live reading:
  `(vram_used − weights) / ctx_total`. Captures KV-quant / flash-attn / MTP
  implicitly. `nil` when the inputs aren't usable.
  """
  @spec per_ctx_mb(number() | nil, number() | nil, integer() | nil) :: float() | nil
  def per_ctx_mb(weights_mb, used_mb, ctx_total)
      when is_number(weights_mb) and is_number(used_mb) and is_integer(ctx_total) and
             ctx_total > 0 do
    nonweights = used_mb - weights_mb
    if nonweights > 0, do: nonweights / ctx_total, else: nil
  end

  def per_ctx_mb(_weights_mb, _used_mb, _ctx_total), do: nil

  @doc "Projected VRAM (MB) for a context total: weights + per-token cost × ctx_total."
  @spec project(number(), number(), number()) :: float()
  def project(weights_mb, per_ctx_mb, ctx_total_new),
    do: weights_mb + per_ctx_mb * ctx_total_new

  @doc """
  Validate a (re)load against VRAM. `opts`:
  `weights_mb`, `total_mb`, `ctx_total_new`, and — for a **resident** model —
  `used_mb`, `ctx_total_current`, `resident?: true`.

  Returns `fits?`:
  - `true` / `false` — calibrated projection within / over the 95% budget (resident);
  - `:cold` — not calibratable, but the weights alone fit (KV unvalidated);
  - `false` — even the weights exceed the budget (a definite block);
  - `:unknown` — no telemetry / size.
  """
  @spec validate(map()) :: validation()
  def validate(opts) do
    do_validate(budget_mb(opts[:total_mb]), opts[:weights_mb], opts)
  end

  defp do_validate(nil, _weights, _opts), do: unknown()
  defp do_validate(_budget, nil, _opts), do: unknown()

  defp do_validate(budget, weights, opts) do
    per_ctx = opts[:resident?] && per_ctx_mb(weights, opts[:used_mb], opts[:ctx_total_current])
    new_total = opts[:ctx_total_new]

    if is_number(per_ctx) and is_number(new_total) do
      projected = Float.round(project(weights, per_ctx, new_total), 1)
      %{projected_mb: projected, budget_mb: budget, fits?: projected <= budget}
    else
      # Cold / uncalibratable: only the weights floor is certain.
      fits = if weights > budget, do: false, else: :cold
      %{projected_mb: Float.round(weights, 1), budget_mb: budget, fits?: fits}
    end
  end

  defp unknown, do: %{projected_mb: nil, budget_mb: nil, fits?: :unknown}

  defp budget_mb(total) when is_number(total), do: Float.round(total * @vram_margin, 1)
  defp budget_mb(_total), do: nil
end
