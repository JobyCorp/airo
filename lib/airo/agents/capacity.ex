defmodule Airo.Agents.Capacity do
  @moduledoc """
  Memory-fit estimation for loading a model onto a host slot (S18, see
  [DESIGN-agent-placement.md](../../../DESIGN-agent-placement.md)).

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
  Host memory headroom from a GPU telemetry map (string- or atom-keyed), or
  `:unavailable` when the host reports no usable telemetry.
  """
  @spec headroom(map() | nil) :: headroom()
  def headroom(gpu) when is_map(gpu) do
    total = num(gpu, :vram_total_mb)
    used = num(gpu, :vram_used_mb)

    if fetch(gpu, :available) == true and is_number(total) and is_number(used) do
      %{total_mb: total, used_mb: used, free_mb: Float.round(total - used, 1)}
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
end
