defmodule Airo.Routing.Affinity do
  @moduledoc """
  Session affinity for aliases with `strategy: :affinity` (S29).

  A client names a session with `route.affinity` (a string of at most 128
  bytes). The first request with a key assigns it the candidate deployment
  with the fewest in-flight requests; later requests with the same key put
  that deployment first, so consecutive rounds of one session land on the
  same card and hit its prefix cache. The rest of the list keeps the
  round-robin order, so failover is unchanged.

  Assignments live in the routing ETS table (`Airo.Runtime.Store`) as
  `{{:affinity, alias_id, key}, deployment_id, last_seen_ms}`. They are
  runtime state: a node restart forgets them, and the next request assigns
  again.

  The outcome of each call is one of:

    - `:assigned` — the key was new (or had been idle past `idle_ms/0`).
    - `:hit` — the key's deployment is still a live candidate and came first.
    - `:reassigned` — the key's deployment is disabled, filtered out, or
      `:down`, so the key moved to the least busy live candidate.
    - `:none` — no key, or the alias does not use the strategy.
  """

  alias Airo.Gateway.InFlight
  alias Airo.Health
  alias Airo.Runtime.Store

  @idle_ms 30 * 60 * 1000
  @max_key_bytes 128

  @type outcome :: :assigned | :hit | :reassigned | :none

  @doc "The longest `route.affinity` key accepted, in bytes."
  def max_key_bytes, do: @max_key_bytes

  @doc "A key idle for longer than this (ms) is dropped and assigned again."
  def idle_ms, do: @idle_ms

  @doc """
  True when `route.affinity` is absent or a string of at most
  `max_key_bytes/0` bytes. Any other value is a client error.
  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(nil), do: true
  def valid_key?(key) when is_binary(key), do: byte_size(key) <= @max_key_bytes
  def valid_key?(_key), do: false

  @doc "The affinity key in `route`, or nil. An empty string is no key."
  @spec key(map()) :: String.t() | nil
  def key(%{"affinity" => key}) when is_binary(key) and key != "", do: key
  def key(_route), do: nil

  @doc "The deployment id `key` is assigned to under `alias_id`, or nil."
  @spec assignment(integer(), String.t()) :: integer() | nil
  def assignment(alias_id, key) do
    case :ets.lookup(Store.routing_table(), {:affinity, alias_id, key}) do
      [{_, deployment_id, _last_seen}] -> deployment_id
      [] -> nil
    end
  end

  @doc """
  Reorder `candidates` (already in failover order) for `key`: the key's
  deployment first, the rest in their existing order. Returns the new order
  and the outcome. A nil key returns `candidates` unchanged with `:none`.
  """
  @spec order([map()], integer(), String.t() | nil) :: {[map()], outcome()}
  def order(candidates, _alias_id, nil), do: {candidates, :none}
  def order([], _alias_id, _key), do: {[], :none}

  def order(candidates, alias_id, key) do
    now = now()
    entry = {:affinity, alias_id, key}

    case lookup(entry, now) do
      {:ok, deployment_id} ->
        case find(candidates, deployment_id) do
          %{} = candidate ->
            if Health.status(deployment_id) == :down do
              reassign(candidates, alias_id, entry, now)
            else
              :ets.update_element(Store.routing_table(), entry, {3, now})
              {promote(candidates, candidate), :hit}
            end

          nil ->
            reassign(candidates, alias_id, entry, now)
        end

      :miss ->
        assign(candidates, alias_id, entry, now)
    end
  end

  ## Internal

  defp lookup(entry, now) do
    case :ets.lookup(Store.routing_table(), entry) do
      [{^entry, deployment_id, last_seen}] ->
        if now - last_seen > @idle_ms do
          :ets.delete(Store.routing_table(), entry)
          :miss
        else
          {:ok, deployment_id}
        end

      [] ->
        :miss
    end
  end

  # A new key. `insert_new` settles a race between two first requests of one
  # session: the loser follows the winner's assignment instead of splitting
  # the session across two cards.
  defp assign(candidates, alias_id, entry, now) do
    sweep(now)
    candidate = pick(candidates, alias_id)

    if :ets.insert_new(Store.routing_table(), {entry, candidate.deployment.id, now}) do
      {promote(candidates, candidate), :assigned}
    else
      order(candidates, alias_id, elem(entry, 2))
    end
  end

  defp reassign(candidates, alias_id, entry, now) do
    candidate = pick(candidates, alias_id)
    :ets.insert(Store.routing_table(), {entry, candidate.deployment.id, now})
    {promote(candidates, candidate), :reassigned}
  end

  # The least busy candidate that is not `:down` (any candidate when all are
  # down): fewest in-flight requests, then fewest live keys on this alias,
  # then the round-robin position, so simultaneous new sessions at idle still
  # spread across cards.
  defp pick(candidates, alias_id) do
    pool =
      case Enum.reject(candidates, &(Health.status(&1.deployment.id) == :down)) do
        [] -> candidates
        live -> live
      end

    keys = keys_per_deployment(alias_id)

    pool
    |> Enum.with_index()
    |> Enum.min_by(fn {candidate, index} ->
      id = candidate.deployment.id
      {InFlight.count(id), Map.get(keys, id, 0), index}
    end)
    |> elem(0)
  end

  defp keys_per_deployment(alias_id) do
    Store.routing_table()
    |> :ets.select([{{{:affinity, alias_id, :_}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.frequencies()
  end

  # Drop every key idle past the window. Runs only when a new key is assigned,
  # so the table stays bounded by the sessions of the last `idle_ms`.
  defp sweep(now) do
    cutoff = now - @idle_ms

    :ets.select_delete(Store.routing_table(), [
      {{{:affinity, :_, :_}, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  defp find(candidates, deployment_id),
    do: Enum.find(candidates, &(&1.deployment.id == deployment_id))

  defp promote(candidates, candidate),
    do: [candidate | Enum.reject(candidates, &(&1.deployment.id == candidate.deployment.id))]

  defp now, do: System.monotonic_time(:millisecond)
end
