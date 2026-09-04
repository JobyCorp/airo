defmodule Airo.Agents.Ingest do
  @moduledoc """
  Channel-facing translation of agent pushes into Airo state (Model 2).

  - `register/2` — structural + state: upsert the Agent and its slot-Providers
    (`Airo.Agents.register/2`), then apply each slot's pushed state.
  - `slot/2` — one slot transition (load/up/down/swap).
  - `host_down/1` — the agent disconnected: mark every deployment of its managed
    providers down and clear its slot state.

  Each slot push does two things (S17):

  1. **Resident-model state** → `Airo.Agents.SlotState`: the authoritative record
     of which model is loaded in the slot, sourced from the push. The `/agents` UI
     reads this — it is *not* inferred from deployments, since loading a model
     writes no `deployments` row.
  2. **Deployment health** (where deployments exist): a deployment whose
     `model_name` matches the resident model takes the slot's status, the rest are
     `:down`. This REPLACES the prober for agent-managed providers (the prober
     skips any provider with an `agent_id`), so routing still has a health signal
     for any deployment an operator binds to the slot.

  Both are broadcast on `agent:<host_id>` so the live UI updates without polling.
  """
  require Logger

  alias Airo.{Agents, Config, Health, Repo}
  alias Airo.Agents.{Control, Lifecycle, Liveness, Provenance, SlotState}

  @doc "Full registration (on channel join/rejoin): structure + per-slot reconcile."
  def register(host_id, payload) when is_binary(host_id) and is_map(payload) do
    case Agents.register(host_id, payload) do
      {:ok, %{agent: agent, changes: changes}} ->
        slots = Map.get(payload, "slots", [])
        record_changes(host_id, agent, changes)
        Liveness.registered(host_id)

        :telemetry.execute([:airo, :agent, :register], %{count: 1, slots: length(slots)}, %{
          host_id: host_id
        })

        index = inventory_index(host_id)
        Enum.each(slots, &apply_slot(host_id, &1, index))
        :ok

      {:error, reason} ->
        Logger.warning("agent #{host_id}: register failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "A single slot transition (load/up/down/swap)."
  def slot(host_id, slot) when is_binary(host_id) and is_map(slot) do
    :telemetry.execute([:airo, :agent, :slot], %{count: 1}, %{
      host_id: host_id,
      port: slot["port"],
      status: slot["status"],
      reason: slot["reason"]
    })

    apply_slot(host_id, slot, inventory_index(host_id))
  end

  # A register that carried a different agent identity than the row held is a
  # lifecycle event (S25). A plain heartbeat reaches here with `[]` and writes
  # nothing.
  defp record_changes(host_id, agent, changes) do
    Enum.each(changes, fn {field, from, to} ->
      Lifecycle.transition(host_id, :"#{field}_changed",
        agent: agent,
        reason: "#{field} #{from} -> #{to}",
        meta: %{field: field, from: from, to: to}
      )
    end)
  end

  @doc "The agent's socket dropped — mark its deployments down and forget slot state."
  def host_down(host_id) do
    case Config.get_agent_by_host_id(host_id) do
      %{} = agent ->
        providers = agent |> Repo.preload(providers: :deployments) |> Map.fetch!(:providers)

        # Note the clusters this host took part in *before* clearing its state —
        # afterwards there is nothing left to say which they were.
        clusters =
          providers
          |> Enum.map(&(SlotState.get(&1.id) || %{}))
          |> Enum.map(& &1[:cluster_id])
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        Enum.each(providers, fn provider ->
          Enum.each(provider.deployments, fn deployment ->
            Health.mark_deployment(deployment, provider, :down,
              source: :agent,
              reason: "agent_disconnected"
            )
          end)

          SlotState.clear(provider.id)
        end)

        # Losing any rank breaks the whole load, so a head on a host that is
        # still connected has to be taken down with its missing peer.
        Enum.each(clusters, &refresh_cluster_head/1)

        broadcast(host_id)

      _ ->
        :ok
    end
  end

  # Apply one slot's pushed state: reconcile the resident model into the Shelf
  # (identity + provenance), record runtime state (SlotState), and derive
  # deployment health by **identity** — the deployment linked to the resident
  # Model is up, the rest are down.
  defp apply_slot(host_id, slot, index) do
    case Config.get_provider_by_name(slot_name(host_id, slot)) do
      %{} = provider ->
        cluster = cluster_attrs(slot)
        model = if peer?(cluster), do: nil, else: reconcile(host_id, provider, slot, index)

        SlotState.put(provider.id, slot_attrs(slot, cluster, model))

        if peer?(cluster) do
          demote_peer(provider)
          # This rank doesn't serve, but it decides whether the head can.
          refresh_cluster_head(cluster.cluster_id)
        else
          record_launch_profile(slot)

          mark_deployments(
            provider,
            model && model.id,
            head_status(slot, cluster),
            slot_context(slot)
          )
        end

        broadcast(host_id)

      _ ->
        :ok
    end
  end

  defp reconcile(host_id, provider, slot, index) do
    provenance = if id = slot["resident_model"], do: Map.get(index, id)
    Provenance.reconcile(host_id, provider, slot, provenance)
  end

  # Persist the running launch recipe (`Airo.Agents.record_live_profile/2`), so a
  # load Airo didn't initiate still survives the slot going down.
  #
  # Only a **head** that reached `up` is recorded, and only from a push that
  # carries a profile:
  #
  #   - a peer rank's profile is its shard of the launch, not the body that
  #     reproduces the cluster (the head's is — posting it starts every rank);
  #   - while `loading` the agent echoes the *requested* profile, defaults not
  #     yet resolved, and a load that then fails is no recipe at all;
  #   - `profile` rides only the heartbeat register, so transition pushes simply
  #     leave the recorded recipe alone until the next beat.
  defp record_launch_profile(%{"status" => "up", "resident_model" => model, "profile" => profile})
       when is_binary(model) and is_map(profile) do
    Agents.record_live_profile(model, profile)
  end

  defp record_launch_profile(_slot), do: :ok

  defp slot_attrs(slot, cluster, model) do
    %{
      resident_model: slot["resident_model"],
      revision: slot["revision"],
      status: slot["status"],
      reason: clip(slot["reason"]),
      ctx: slot["ctx"],
      parallel: slot["parallel"],
      ctx_total: slot["ctx_total"],
      engine_build: slot["engine_build"],
      profile: slot["profile"],
      cluster_id: cluster.cluster_id,
      tp_rank: cluster.tp_rank,
      tp_size: cluster.tp_size,
      # Recorded so a peer's push can find the head's resident deployment without
      # re-running provenance (which would re-fetch inventory over HTTP).
      model_id: model && model.id
    }
  end

  # The agent sends the shared load id as `deployment_id`. It is a *load* id and
  # has nothing to do with `Airo.Config.Deployment`, so it is carried internally
  # as `cluster_id` to keep the two from being confused.
  defp cluster_attrs(slot) do
    %{
      cluster_id: presence(slot["deployment_id"] || slot["cluster_id"]),
      tp_rank: as_int(slot["tp_rank"]),
      tp_size: as_int(slot["tp_size"])
    }
  end

  # Rank 0 (or an unclustered slot) is the head — the only rank serving the API.
  defp peer?(%{tp_rank: rank}) when is_integer(rank), do: rank > 0
  defp peer?(_cluster), do: false

  ## Deployment health

  # Derive health by **identity**: the deployment linked to the resident Model
  # takes the slot's status, the rest are down.
  defp mark_deployments(provider, resident_model_id, {resident_status, reason}, ctx) do
    # Reload deployments — reconcile may have re-linked one's model_id.
    %{deployments: deployments} = Repo.preload(provider, :deployments, force: true)

    Enum.each(deployments, fn deployment ->
      resident? = resident_model_id && deployment.model_id == resident_model_id

      {status, why} =
        if resident?, do: {resident_status, reason}, else: {:down, "not_resident"}

      if resident?, do: sync_context_window(deployment, ctx)
      Health.mark_deployment(deployment, provider, status, source: :agent, reason: clip(why))
    end)
  end

  # The engine's own report is the authority on a slot's serving context — keep
  # the resident deployment's `context_window` (what `/v1/models` publishes as
  # `context_length`) in step with what is actually loaded, load after load.
  defp sync_context_window(%{context_window: ctx}, ctx), do: :ok

  defp sync_context_window(deployment, ctx) when is_integer(ctx) and ctx > 0 do
    case Config.update_deployment(deployment, %{context_window: ctx}) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "slot ctx sync failed for deployment #{deployment.id}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp sync_context_window(_deployment, _ctx), do: :ok

  # Per-request serving context out of a slot push: the agent's `ctx` is already
  # per sequence; a push carrying only the engine total is divided across the
  # `parallel` sequences that share it.
  defp slot_context(slot),
    do: per_request_ctx(as_int(slot["ctx"]), as_int(slot["ctx_total"]), as_int(slot["parallel"]))

  defp per_request_ctx(ctx, _total, _parallel) when is_integer(ctx), do: ctx

  defp per_request_ctx(_ctx, total, parallel)
       when is_integer(total) and is_integer(parallel) and parallel > 1,
       do: div(total, parallel)

  defp per_request_ctx(_ctx, total, _parallel), do: total

  # A peer rank holds a shard of the weights and serves no API. Nothing should
  # ever be routed at it, so any deployment bound to one (hand-created, or left
  # behind by a slot that used to be a head) is forced down rather than left
  # looking healthy on a port that answers nothing.
  defp demote_peer(provider) do
    %{deployments: deployments} = Repo.preload(provider, :deployments, force: true)

    Enum.each(deployments, fn deployment ->
      Health.mark_deployment(deployment, provider, :down, source: :agent, reason: "tp_peer")
    end)
  end

  # A tensor-parallel cluster is exactly as healthy as its worst rank: if a peer
  # is down the head's engine cannot serve, however healthy the head looks by
  # itself. Fold every member's status into the head's own before marking.
  defp head_status(slot, %{cluster_id: nil}), do: status_for(slot["status"], slot["reason"])

  defp head_status(slot, cluster) do
    members = SlotState.members(cluster.cluster_id)
    degraded = Enum.find(members, fn {_id, record} -> degraded_rank?(record) end)

    cond do
      # A rank that has gone silent leaves no record at all, so absence — not
      # just a `down` status — is what a lost peer looks like here.
      incomplete?(members, cluster.tp_size) ->
        {:down, "tp_cluster_incomplete"}

      degraded ->
        {_id, record} = degraded
        status_for(cluster_status(record), cluster_reason(record))

      true ->
        status_for(slot["status"], slot["reason"])
    end
  end

  defp incomplete?(members, tp_size) when is_integer(tp_size) and tp_size > 1,
    do: length(members) < tp_size

  defp incomplete?(_members, _tp_size), do: false

  # An empty peer means the cluster never formed; treat it as down, not as idle.
  defp degraded_rank?(%{tp_rank: rank} = record) when is_integer(rank) and rank > 0,
    do: record[:status] != :up

  defp degraded_rank?(_record), do: false

  defp cluster_status(%{status: :loading}), do: "loading"
  defp cluster_status(_record), do: "down"

  defp cluster_reason(%{tp_rank: rank, status: status}), do: "tp_rank_#{rank}_#{status}"

  # Re-derive the head's deployment health after a peer moved. The head's own
  # push already linked its resident Model, so read that back from its slot state
  # rather than reconciling again.
  defp refresh_cluster_head(nil), do: :ok

  defp refresh_cluster_head(cluster_id) do
    members = SlotState.members(cluster_id)

    with {provider_id, head} <- Enum.find(members, fn {_id, r} -> SlotState.head?(r) end),
         %{} = provider <- Config.get_provider(provider_id) do
      cluster = %{cluster_id: cluster_id, tp_rank: head[:tp_rank], tp_size: head[:tp_size]}
      own = %{"status" => to_string(head.status), "reason" => head[:reason]}
      ctx = per_request_ctx(head[:ctx], head[:ctx_total], head[:parallel])

      mark_deployments(provider, head[:model_id], head_status(own, cluster), ctx)
    else
      _ -> :ok
    end
  end

  # Resident-model id → inventory provenance map, fetched once per register/slot.
  # Empty (no enrichment) when the agent's control API is unreachable — identity
  # still reconciles from the push.
  defp inventory_index(host_id) do
    with %{} = agent <- Config.get_agent_by_host_id(host_id),
         {:ok, models} <- Control.inventory(agent) do
      Map.new(models, &{&1["id"], &1})
    else
      _ -> %{}
    end
  end

  @doc "PubSub topic carrying a host's slot-state changes (distinct from the channel topic)."
  def slots_topic(host_id), do: "agent_slots:#{host_id}"

  # Tell live views watching this host that its slot state changed. Uses a
  # dedicated topic — broadcasting on the channel topic ("agent:<host_id>") would
  # deliver this to the AgentChannel process, which doesn't expect it.
  defp broadcast(host_id) do
    Phoenix.PubSub.broadcast(Airo.PubSub, slots_topic(host_id), {:agent_slots, host_id})
  end

  defp slot_name(host_id, slot), do: "#{host_id}:#{slot["port"]}"

  # The resident model's status. A loading slot is :unknown (don't route yet but
  # don't hard-fail); empty/crashed is :down.
  defp status_for("up", _reason), do: {:up, nil}
  defp status_for("loading", _reason), do: {:unknown, "loading"}
  defp status_for("down", reason), do: {:down, reason || "down"}
  defp status_for("failed", reason), do: {:down, reason || "failed"}
  defp status_for(_empty_or_nil, _reason), do: {:down, "empty"}

  defp clip(nil), do: nil
  defp clip(reason), do: reason |> to_string() |> String.slice(0, 255)

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil

  defp as_int(value) when is_integer(value), do: value

  defp as_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp as_int(_value), do: nil
end
