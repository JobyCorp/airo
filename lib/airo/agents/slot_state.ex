defmodule Airo.Agents.SlotState do
  @moduledoc """
  Per-slot **resident-model runtime state**, kept in ETS (S17, see
  [DESIGN-agent-management.md](../../../docs/design/DESIGN-agent-management.md) §3).

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
          cluster_id: String.t() | nil,
          tp_rank: non_neg_integer() | nil,
          tp_size: pos_integer() | nil,
          model_id: integer() | nil,
          resident_since: DateTime.t() | nil,
          updated_at: integer()
        }

  @doc """
  Record a slot's resident-model state. `attrs` keys: `resident_model`,
  `revision`, `status`, `reason`, the serving facts `ctx`/`parallel`/`ctx_total`/
  `engine_build`, and the resolved `profile` (KV quant, flash-attn, MTP, …).

  `profile` rides only the (heartbeat) register, not slot transition events, so it
  is **preserved** when a push omits it — a status flip shouldn't blank the
  serving profile.

  `resident_since` is stamped in **wall clock** (everything else here is
  monotonic) and holds when the *current* model became resident: it survives
  status flips and heartbeats, and only resets when the resident model actually
  changes. External consumers use it to spot a reload they didn't initiate.

  ## Multi-node tensor parallelism

  A model too large for one host runs as one logical load spanning several slots
  on different hosts. Every participating slot reports the same `cluster_id`
  (the agent sends it as `deployment_id` — a *load* id, unrelated to Airo's
  `Airo.Config.Deployment`) plus its own `tp_rank` and the group's `tp_size`.

  Rank 0 is the head: it is the only rank that serves the OpenAI API, so it is
  the only one a deployment ever binds to. Ranks above 0 hold a shard of the
  weights and serve nothing — they exist here purely so the fleet can see that
  the host's VRAM is spoken for and that the cluster is whole.
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
      cluster_id: attrs[:cluster_id],
      tp_rank: attrs[:tp_rank],
      tp_size: attrs[:tp_size],
      model_id: attrs[:model_id],
      resident_since: resident_since(prior, attrs[:resident_model]),
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

  @doc """
  Every slot participating in a multi-node load, as `{provider_id, record}`.

  Members of one cluster live on *different hosts*, so there is no key prefix to
  match on — this scans the table. That is fine at fleet scale (one row per slot,
  dozens at most) and keeps cluster membership derived from what the ranks
  actually report rather than from a second source of truth that could drift.
  """
  @spec members(String.t() | nil) :: [{integer(), record()}]
  def members(nil), do: []

  def members(cluster_id) do
    Store.slots_table()
    |> :ets.tab2list()
    |> Enum.filter(fn {_provider_id, record} -> record[:cluster_id] == cluster_id end)
    |> Enum.sort_by(fn {provider_id, record} -> {record[:tp_rank] || 0, provider_id} end)
  end

  @doc "True when the slot is the rank that serves the API (rank 0, or not clustered)."
  @spec head?(record() | nil) :: boolean()
  def head?(nil), do: false
  def head?(%{tp_rank: rank}) when is_integer(rank), do: rank == 0
  def head?(_record), do: true

  @doc "Forget a slot's state (host disconnected, or slot deregistered)."
  @spec clear(integer()) :: :ok
  def clear(provider_id) do
    :ets.delete(Store.slots_table(), provider_id)
    :ok
  end

  # Keep the prior stamp while the same model stays resident; stamp afresh when
  # the model changes. An empty slot has nothing resident, so no stamp.
  defp resident_since(_prior, model) when model in [nil, ""], do: nil

  defp resident_since(%{resident_model: same, resident_since: %DateTime{} = since}, model)
       when same == model,
       do: since

  defp resident_since(_prior, _model), do: DateTime.utc_now() |> DateTime.truncate(:second)

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
