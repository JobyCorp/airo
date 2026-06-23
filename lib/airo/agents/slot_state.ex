defmodule Airo.Agents.SlotState do
  @moduledoc """
  Per-slot **resident-model runtime state**, kept in ETS (S17, see
  [DESIGN-agent-management.md](../../../DESIGN-agent-management.md) §3).

  A managed slot Provider holds at most one model at a time; *which* model is
  resident — and whether it is `loading`/`up`/`down` — is runtime state the agent
  reports over its channel (`AiroAgent.SlotInfo`), not config and not derivable
  from deployments (loading a model writes no `deployments` row). So it lives
  here, keyed by the slot's `provider_id`, alongside `Airo.Health` rather than in
  Postgres: it is volatile and **self-heals on agent re-register** (an absent slot
  ⇒ no state ⇒ treated as empty/down by readers).

  `Airo.Agents.Ingest` writes this from each `register`/`slot` push and clears it
  on host disconnect; readers (the `/agents` UI) call `get/1`.
  """

  alias Airo.Runtime.Store

  @type status :: :empty | :loading | :up | :down

  @type record :: %{
          resident_model: String.t() | nil,
          revision: String.t() | nil,
          status: status(),
          reason: String.t() | nil,
          ctx: pos_integer() | nil,
          parallel: pos_integer() | nil,
          ctx_total: pos_integer() | nil,
          engine_build: String.t() | nil,
          profile: map() | nil,
          updated_at: integer()
        }

  @doc """
  Record a slot's resident-model state. `attrs` keys: `resident_model`,
  `revision`, `status`, `reason`, the serving facts `ctx`/`parallel`/`ctx_total`/
  `engine_build`, and the resolved `profile` (KV quant, flash-attn, MTP, …).

  `profile` rides only the (heartbeat) register, not slot transition events, so it
  is **preserved** when a push omits it — a status flip shouldn't blank the
  serving profile.
  """
  @spec put(integer(), map()) :: record()
  def put(provider_id, attrs) when is_integer(provider_id) and is_map(attrs) do
    prior = get(provider_id) || %{}

    record = %{
      resident_model: attrs[:resident_model],
      revision: attrs[:revision],
      status: normalize_status(attrs[:status]),
      reason: attrs[:reason],
      ctx: attrs[:ctx],
      parallel: attrs[:parallel],
      ctx_total: attrs[:ctx_total],
      engine_build: attrs[:engine_build],
      profile: attrs[:profile] || prior[:profile],
      updated_at: now()
    }

    :ets.insert(Store.slots_table(), {provider_id, record})
    record
  end

  @doc "Resident-model state for a slot, or `nil` if the agent hasn't reported it."
  @spec get(integer()) :: record() | nil
  def get(provider_id) do
    case :ets.lookup(Store.slots_table(), provider_id) do
      [{^provider_id, record}] -> record
      [] -> nil
    end
  end

  @doc "Forget a slot's state (host disconnected, or slot deregistered)."
  @spec clear(integer()) :: :ok
  def clear(provider_id) do
    :ets.delete(Store.slots_table(), provider_id)
    :ok
  end

  # The agent reports the slot's steady state (`empty|loading|up`) and terminal
  # transitions (`down|failed`). Anything unrecognized is treated as down rather
  # than guessed up — a slot we can't read is not routable.
  defp normalize_status(s) when s in [:empty, :loading, :up, :down], do: s
  defp normalize_status("up"), do: :up
  defp normalize_status("loading"), do: :loading
  defp normalize_status("empty"), do: :empty
  defp normalize_status(nil), do: :empty
  defp normalize_status("down"), do: :down
  defp normalize_status("failed"), do: :down
  defp normalize_status(_other), do: :down

  defp now, do: System.monotonic_time(:millisecond)
end
