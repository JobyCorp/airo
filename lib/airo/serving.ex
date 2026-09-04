defmodule Airo.Serving do
  @moduledoc """
  Read-only **serving topology** — the answer to "which box is serving what",
  assembled for consumers outside Airo (orchester, Prometheus, dashboards).

  Everything here is a projection of state Airo already keeps; nothing in this
  module writes. Three sources are joined:

    - **Config** (Postgres) — agents, providers, deployments, models, aliases.
    - **`Airo.Agents.SlotState`** (ETS) — which model is *actually* resident in
      each managed slot, pushed by the host agent. Loading a model writes no
      `deployments` row, so this is the only place residency lives.
    - **`Airo.Health`** (ETS) — the per-deployment health snapshot.

  ## Two things external consumers get wrong

  **Health is stale-able.** `Airo.Health` decays a snapshot to `:unknown` after
  `staleness_ms`, but the raw record keeps its last status. Every health map
  here therefore carries `status` (already decayed), `age_ms`, and `stale` — a
  consumer that reads `status` alone can otherwise report a dead host as healthy
  for the length of the staleness window.

  **Health is a preference, not a gate.** `Airo.Routing` drops
  disabled deployments/providers outright, but still *tries* a `:down`
  candidate last rather than refusing a freshly-reloaded endpoint. So each
  deployment reports both:

    - `eligible` — passes the hard config gate (deployment **and** provider
      enabled). A false here means Airo will never dispatch to it.
    - `routable` — eligible *and* currently healthy, i.e. Airo would prefer it.
      A deployment that is eligible but not routable is still a last-resort
      candidate.

  Note that `agent.enabled` is reported on the host but is **not** part of
  `eligible`: routing gates on the provider, not on the agent that manages it.

  ## Model identity

  The agent's model id (`Qwen3.6-35B-…gguf`) is not unique — the same artifact
  is copied across hosts. `Airo.Agents.Provenance` therefore keys Airo's
  canonical `Model` by a host/slot-qualified `upstream_model_id`. Resident
  models expose both, and `upstream_model_id` is the id to join on.
  """

  import Ecto.Query, warn: false

  alias Airo.Agents.{Capacity, Control, SlotState}
  alias Airo.Config.Provider
  alias Airo.Agents.{HostEvent, Liveness}
  alias Airo.Health.HealthEvent
  alias Airo.Usage.UsageRecord
  alias Airo.{Config, Health, Repo}

  # Per-host control-API budget when `inventory: true`. Inventory is an outbound
  # HTTP call per host, so it stays opt-in and never blocks the snapshot for long.
  @inventory_timeout_ms 4_000

  @default_limit 500
  @max_limit 5_000

  ## ------------------------------------------------------------------
  ## Topology
  ## ------------------------------------------------------------------

  @doc """
  Full serving topology.

  Options:

    - `:inventory` — when true, also call each host agent's control API for the
      models it holds **on disk** (not just what's loaded) and use the reported
      `size_bytes` to fill in per-slot capacity math. Off by default: it is one
      outbound HTTP call per host.
  """
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    agents =
      Config.list_agents()
      |> Repo.preload(providers: [deployments: :model])

    external =
      Provider
      |> where([p], is_nil(p.agent_id))
      |> order_by([p], p.name)
      |> preload(deployments: :model)
      |> Repo.all()

    aliases =
      Config.list_aliases()
      |> Repo.preload(candidates: [deployment: [:provider, :model]])

    activity = deployment_activity()
    inventories = if opts[:inventory], do: inventories(agents), else: %{}

    hosts = Enum.map(agents, &host(&1, activity, Map.get(inventories, &1.id)))

    %{
      generated_at: now(),
      staleness_ms: Health.staleness_ms(),
      hosts: hosts,
      clusters: clusters(hosts),
      external_providers: Enum.map(external, &external_provider(&1, activity)),
      aliases: Enum.map(aliases, &alias_entry/1)
    }
  end

  # Multi-node loads, joined back into one logical entry. The per-host slots
  # already carry `resident.cluster`, but a consumer asking "is this model
  # actually being served" would otherwise have to scan every host and group by
  # hand — and get the completeness rule wrong.
  defp clusters(hosts) do
    for host <- hosts,
        slot <- host.slots,
        cluster = slot.resident && slot.resident.cluster,
        cluster != nil do
      {cluster, host, slot}
    end
    |> Enum.group_by(fn {cluster, _host, _slot} -> cluster.id end)
    |> Enum.map(fn {id, entries} -> cluster_entry(id, entries) end)
    |> Enum.sort_by(& &1.id)
  end

  defp cluster_entry(id, entries) do
    members =
      entries
      |> Enum.map(fn {cluster, host, slot} ->
        %{
          host_id: host.host_id,
          slot: slot.provider,
          base_url: slot.base_url,
          tp_rank: cluster.tp_rank,
          serves_api: slot.serves_api,
          status: slot.resident.status
        }
      end)
      |> Enum.sort_by(&(&1.tp_rank || 0))

    {cluster, _host, _slot} = hd(entries)
    {_c, _h, head_slot} = Enum.find(entries, hd(entries), fn {_c, _h, s} -> s.serves_api end)

    %{
      id: id,
      model: head_slot.resident.model,
      upstream_model_id: head_slot.resident.upstream_model_id,
      tp_size: cluster.tp_size,
      members: members,
      # A rank that has gone silent leaves no slot behind, so membership is
      # counted against the declared tp_size rather than trusted as complete.
      complete: complete?(members, cluster.tp_size),
      serving: complete?(members, cluster.tp_size) and Enum.all?(members, &(&1.status == :up))
    }
  end

  defp complete?(members, tp_size) when is_integer(tp_size) and tp_size > 0,
    do: length(members) >= tp_size

  defp complete?(_members, _tp_size), do: true

  defp host(agent, activity, inventory) do
    index = inventory_index(inventory)
    slots = sort_by_name(agent.providers)

    # The host reports one VRAM figure for the whole GPU, so per-KV-token cost
    # can only be attributed to a slot when it is the only one holding a model.
    sole_resident? = Enum.count(slots, &resident_slot?/1) == 1

    %{
      host_id: agent.host_id,
      control_url: agent.control_url,
      agent_version: agent.version,
      enabled: agent.enabled,
      last_seen_at: agent.last_seen_at,
      # Liveness beyond `last_seen_at` (S25): `online` is the open channel,
      # `stale` is online-but-silent past the configured window. `role` is the
      # S26 concept; every host is a controller until an agent says otherwise.
      online: Liveness.online?(agent.host_id),
      stale: Liveness.stale?(agent.host_id),
      role: "controller",
      gpu: gpu(agent.gpu),
      inventory: inventory && Enum.map(inventory, &inventory_entry/1),
      slots: Enum.map(slots, &slot(&1, agent, activity, index, sole_resident?))
    }
  end

  defp resident_slot?(provider) do
    case SlotState.get(provider.id) do
      %{resident_model: model} when model not in [nil, ""] -> true
      _ -> false
    end
  end

  # `Capacity.headroom/1` returns `:unavailable` when the host reports no usable
  # telemetry. Surfacing that as `available: false` keeps "no reading" distinct
  # from "genuinely zero free" — a scheduler must not treat them alike.
  defp gpu(raw) do
    base =
      case Capacity.headroom(raw) do
        %{total_mb: total, used_mb: used, free_mb: free} ->
          %{available: true, vram_total_mb: total, vram_used_mb: used, vram_free_mb: free}

        :unavailable ->
          %{available: false, vram_total_mb: nil, vram_used_mb: nil, vram_free_mb: nil}
      end

    # Utilisation and power come straight from the agent's telemetry map — they
    # aren't part of the headroom arithmetic, but they are what tells a monitor
    # whether a resident model is actually working or merely loaded.
    Map.merge(base, %{
      util_pct: gpu_field(raw, :util_pct),
      power_draw_w: gpu_field(raw, :power_draw_w),
      power_limit_w: gpu_field(raw, :power_limit_w),
      mem_source: gpu_field(raw, :mem_source)
    })
  end

  # GPU maps arrive string-keyed over the channel; tolerate atoms too.
  defp gpu_field(raw, key) when is_map(raw), do: Map.get(raw, key) || Map.get(raw, to_string(key))
  defp gpu_field(_raw, _key), do: nil

  defp slot(provider, agent, activity, index, sole_resident?) do
    state = SlotState.get(provider.id)

    deployments =
      provider.deployments
      |> sort_by_model()
      |> Enum.map(&deployment(&1, provider, activity))

    %{
      provider: provider.name,
      provider_id: provider.id,
      base_url: provider.base_url,
      adapter_type: provider.adapter_type,
      enabled: provider.enabled,
      # Only the head rank of a multi-node load exposes the OpenAI API; a peer's
      # base_url looks perfectly routable and answers nothing.
      serves_api: SlotState.head?(state),
      resident: resident(state, provider, agent, index, sole_resident?),
      deployments: deployments
    }
  end

  # An unreported or empty slot has no resident model — `nil` rather than a map
  # of nils, so a consumer can pattern-match on "nothing loaded here".
  defp resident(nil, _provider, _agent, _index, _sole?), do: nil
  defp resident(%{resident_model: m}, _p, _a, _i, _s) when m in [nil, ""], do: nil

  defp resident(state, provider, agent, index, sole_resident?) do
    model = linked_model(provider, state.resident_model)
    provenance = Map.get(index, state.resident_model)
    size_bytes = provenance && provenance["size_bytes"]

    %{
      model: state.resident_model,
      upstream_model_id: model && model.upstream_model_id,
      display_name: (model && model.display_name) || state.resident_model,
      family: model && model.family,
      quantization: model && model.quantization,
      revision: state.revision || (model && model.revision),
      size: model && model.size,
      size_bytes: size_bytes,
      status: state.status,
      reason: state.reason,
      ctx: state.ctx,
      ctx_total: state.ctx_total,
      parallel: state.parallel,
      engine_build: state.engine_build,
      profile: state.profile,
      cluster: cluster(state),
      resident_since: state.resident_since,
      updated_at: monotonic_to_wall(state.updated_at),
      capacity: capacity(shard_bytes(size_bytes, state), agent.gpu, state, sole_resident?)
    }
  end

  # `nil` for an ordinary single-host load, so a consumer can test one field to
  # know whether a slot is part of something larger.
  defp cluster(%{cluster_id: id}) when id in [nil, ""], do: nil

  defp cluster(state) do
    %{id: state.cluster_id, tp_rank: state.tp_rank, tp_size: state.tp_size}
  end

  # Each rank holds 1/n of the weights, so a host's footprint is its share, not
  # the whole model — a 685B model across two hosts must not read as though each
  # one is carrying all of it.
  defp shard_bytes(nil, _state), do: nil
  defp shard_bytes(size_bytes, state), do: Capacity.shard_bytes(size_bytes, state[:tp_size])

  # Weights floor plus the measured per-KV-token cost, so an external scheduler
  # can size a context change without reimplementing the margin arithmetic.
  # Needs `size_bytes`, which only inventory carries.
  defp capacity(nil, _gpu, _state, _sole?), do: nil

  defp capacity(size_bytes, gpu, state, sole_resident?) do
    weights_mb = Capacity.footprint_mb(size_bytes)

    %{
      weights_mb: weights_mb,
      per_ctx_mb: per_ctx_mb(weights_mb, gpu, state, sole_resident?)
    }
  end

  # Calibration subtracts weights from the host's *total* VRAM reading, so it is
  # only attributable to this slot when no sibling slot also holds a model.
  # Reporting it regardless would silently bill every other slot's KV cache to
  # whichever slot was rendered first.
  defp per_ctx_mb(_weights_mb, _gpu, _state, false), do: nil

  defp per_ctx_mb(weights_mb, gpu, state, true) do
    case Capacity.headroom(gpu) do
      %{used_mb: used} -> Capacity.per_ctx_mb(weights_mb, used, state.ctx_total)
      :unavailable -> nil
    end
  end

  # The Model this slot's resident artifact reconciled to. Provenance links it
  # onto one of the slot's own deployments, so read it back from there rather
  # than guessing by name across providers.
  defp linked_model(provider, resident_id) do
    Enum.find_value(provider.deployments, fn deployment ->
      model = deployment.model

      if model &&
           (model.display_name == resident_id or deployment.model_name == resident_id or
              basename(deployment.model_name) == basename(resident_id)),
         do: model
    end)
  end

  defp external_provider(provider, activity) do
    deployments =
      Enum.map(sort_by_model(provider.deployments), &deployment(&1, provider, activity))

    %{
      provider: provider.name,
      adapter_type: provider.adapter_type,
      base_url: provider.base_url,
      auth_kind: provider.auth_kind,
      enabled: provider.enabled,
      health: provider_health(deployments),
      deployments: deployments
    }
  end

  # Probing is provider-level (one GET /models per upstream), so the provider's
  # health is the best status across its deployments, with that one's latency.
  defp provider_health([]), do: health_map(nil, :unknown)

  defp provider_health(deployments) do
    deployments
    |> Enum.map(& &1.health)
    |> Enum.min_by(&status_rank(&1.status))
  end

  defp deployment(deployment, provider, activity) do
    status = Health.status(deployment.id)
    eligible = deployment.enabled and provider.enabled
    seen = Map.get(activity, deployment.id, %{})

    %{
      id: deployment.id,
      model_name: deployment.model_name,
      upstream_model_id: deployment.model && deployment.model.upstream_model_id,
      display_name: deployment.model && deployment.model.display_name,
      capabilities: deployment.capabilities,
      class: deployment.class,
      tool_use: deployment.tool_use,
      context_window: deployment.context_window,
      enabled: deployment.enabled,
      price_input: deployment.price_input,
      price_output: deployment.price_output,
      health: health_map(Health.get(deployment.id), status),
      eligible: eligible,
      routable: eligible and status == :up,
      routable_reason: routable_reason(deployment, provider, status),
      last_success_at: seen[:last_success_at],
      last_error_at: seen[:last_error_at],
      last_error_code: seen[:last_error_code]
    }
  end

  defp routable_reason(%{enabled: false}, _provider, _status), do: "deployment_disabled"
  defp routable_reason(_deployment, %{enabled: false}, _status), do: "provider_disabled"
  defp routable_reason(_deployment, _provider, :up), do: nil
  defp routable_reason(_deployment, _provider, status), do: "health_#{status}"

  # `Health.status/1` has already decayed a stale snapshot to `:unknown`; `age_ms`
  # and `stale` expose *why*, which the status alone can't distinguish from a
  # genuinely unknown deployment.
  defp health_map(nil, status),
    do: %{status: status, latency_ms: nil, checked_at: nil, age_ms: nil, stale: true}

  defp health_map(%{checked_at: checked_at} = record, status) do
    age = System.monotonic_time(:millisecond) - checked_at

    %{
      status: status,
      latency_ms: record.latency_ms,
      checked_at: monotonic_to_wall(checked_at),
      age_ms: age,
      stale: age > Health.staleness_ms()
    }
  end

  defp alias_entry(alias_) do
    candidates =
      alias_.candidates
      |> Enum.sort_by(&{&1.priority, &1.deployment_id})
      |> Enum.map(&alias_candidate/1)
      |> Enum.reject(&is_nil/1)

    routable = Enum.count(candidates, & &1.routable)

    %{
      name: alias_.name,
      capability: alias_.capability,
      strategy: alias_.strategy,
      router: alias_.router,
      router_mode: alias_.router_mode,
      fallback: alias_.fallback,
      candidates: candidates,
      candidate_count: length(candidates),
      routable_candidates: routable,
      # Eligible, not routable: Airo will still dispatch to a `:down` candidate
      # rather than refuse, so "servable" tracks the hard gate.
      servable: Enum.any?(candidates, & &1.eligible)
    }
  end

  defp alias_candidate(%{deployment: nil}), do: nil

  defp alias_candidate(candidate) do
    deployment = candidate.deployment
    provider = deployment.provider
    status = Health.status(deployment.id)
    eligible = deployment.enabled and provider.enabled

    %{
      deployment_id: deployment.id,
      model_name: deployment.model_name,
      upstream_model_id: deployment.model && deployment.model.upstream_model_id,
      provider: provider.name,
      priority: candidate.priority,
      weight: candidate.weight,
      status: status,
      eligible: eligible,
      routable: eligible and status == :up
    }
  end

  ## ------------------------------------------------------------------
  ## Health transitions
  ## ------------------------------------------------------------------

  @doc """
  Host lifecycle events after `since` (S25) — connects, drops, stale and
  recovered, identity changes — oldest first, with the same cursor contract as
  `health_transitions/1`: pass `next_since` back to continue.
  """
  def host_transitions(opts \\ []) do
    limit = clamp_limit(opts[:limit])

    events =
      HostEvent
      |> apply_since(opts[:since])
      |> order_by([e], asc: e.id)
      |> limit(^(limit + 1))
      |> Repo.all()

    {events, has_more} = split_page(events, limit)

    %{
      generated_at: now(),
      events: Enum.map(events, &host_event/1),
      next_since: next_cursor(events, opts[:since]),
      has_more: has_more
    }
  end

  defp host_event(event) do
    %{
      id: event.id,
      at: event.inserted_at,
      host_id: event.host_id,
      agent_id: event.agent_id,
      kind: event.kind,
      reason: event.reason,
      meta: event.meta
    }
  end

  @doc """
  Health transitions newest-last, for recording flaps rather than only current
  state.

  `:since` is an **event id** cursor (exact) or a `DateTime`/`NaiveDateTime`
  (convenient, but drops events sharing the boundary second). Poll with the
  returned `next_since`.

  Each event carries `previous_status` and `duration_ms` — how long the
  deployment held the state it just left — so flap detection is a filter rather
  than a fold. The event immediately preceding the window is fetched per
  deployment so the first event in a page is not left without a predecessor.
  """
  @spec health_transitions(keyword()) :: map()
  def health_transitions(opts \\ []) do
    limit = clamp_limit(opts[:limit])

    events =
      HealthEvent
      |> apply_since(opts[:since])
      |> order_by([e], asc: e.id)
      |> limit(^(limit + 1))
      |> preload([:provider, :deployment])
      |> Repo.all()

    {events, has_more} = split_page(events, limit)
    predecessors = predecessors(events)

    {transitions, _} =
      Enum.map_reduce(events, predecessors, fn event, prior ->
        previous = Map.get(prior, event.deployment_id)

        entry = transition(event, previous)
        {entry, Map.put(prior, event.deployment_id, event)}
      end)

    %{
      generated_at: now(),
      events: transitions,
      next_since: next_cursor(events, opts[:since]),
      has_more: has_more
    }
  end

  defp transition(event, previous) do
    %{
      id: event.id,
      at: event.inserted_at,
      deployment_id: event.deployment_id,
      model_name: event.deployment && event.deployment.model_name,
      provider: event.provider && event.provider.name,
      provider_id: event.provider_id,
      status: event.status,
      previous_status: previous && previous.status,
      # Airo records a transition when *effective* health changes, and effective
      # health lives in ETS — so an Airo restart resets it to `unknown` and the
      # next probe writes an `up` row after an existing `up` row. Count flaps on
      # `changed`, not on row count, or every restart reads as one.
      changed: previous == nil or previous.status != event.status,
      duration_ms: duration_ms(previous, event),
      source: event.source,
      latency_ms: event.latency_ms,
      reason: event.reason
    }
  end

  defp duration_ms(nil, _event), do: nil

  defp duration_ms(previous, event),
    do: NaiveDateTime.diff(event.inserted_at, previous.inserted_at, :millisecond)

  # The newest event before the window, per deployment appearing in it. Without
  # this the first transition of each deployment in a page has no predecessor and
  # would look like a fresh state rather than a change.
  defp predecessors([]), do: %{}

  defp predecessors(events) do
    deployment_ids =
      events |> Enum.map(& &1.deployment_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    first_id = events |> hd() |> Map.fetch!(:id)

    if deployment_ids == [] do
      %{}
    else
      HealthEvent
      |> where([e], e.deployment_id in ^deployment_ids and e.id < ^first_id)
      |> distinct([e], e.deployment_id)
      |> order_by([e], asc: e.deployment_id, desc: e.id)
      |> Repo.all()
      |> Map.new(&{&1.deployment_id, &1})
    end
  end

  ## ------------------------------------------------------------------
  ## Usage
  ## ------------------------------------------------------------------

  @groupings [:deployment, :model, :alias, :capability, :client_key]

  @doc """
  Token and cost attribution over the records since a cursor, rolled up rather
  than streamed per call.

  Options: `:since` (id cursor or timestamp, as in `health_transitions/1`),
  `:group_by` (one of `#{inspect(@groupings)}`, default `:deployment`), and
  `:limit`.

  The returned `next_since` is the id of the newest record counted, so
  consecutive polls partition the record stream exactly — an accumulating
  consumer never double-counts a call or misses one at a boundary.
  """
  @spec usage_rollup(keyword()) :: map()
  def usage_rollup(opts \\ []) do
    group = grouping(opts[:group_by])
    limit = clamp_limit(opts[:limit])
    query = apply_since(UsageRecord, opts[:since])

    rows =
      query
      |> group_rollup(group)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&cast_rollup/1)

    %{
      generated_at: now(),
      group_by: group,
      rows: rows,
      next_since: Repo.one(from(u in query, select: max(u.id))) || cursor_of(opts[:since])
    }
  end

  defp grouping(value) when value in @groupings, do: value

  defp grouping(value) when is_binary(value) do
    Enum.find(@groupings, :deployment, &(to_string(&1) == value))
  end

  defp grouping(_value), do: :deployment

  defp group_rollup(query, :deployment) do
    from(u in query,
      join: d in assoc(u, :deployment),
      join: p in assoc(d, :provider),
      left_join: a in Airo.Config.Agent,
      on: a.id == p.agent_id,
      group_by: [d.id, d.model_name, p.name, a.host_id],
      order_by: [desc: sum(u.tokens_in) + sum(u.tokens_out)],
      select: %{
        deployment_id: d.id,
        model_name: d.model_name,
        provider: p.name,
        host_id: a.host_id
      }
    )
    |> with_metrics()
  end

  defp group_rollup(query, :model) do
    from(u in query,
      where: not is_nil(u.model_upstream_id),
      group_by: [u.model_upstream_id, u.model_display_name],
      order_by: [desc: sum(u.tokens_in) + sum(u.tokens_out)],
      select: %{upstream_model_id: u.model_upstream_id, display_name: u.model_display_name}
    )
    |> with_metrics()
  end

  defp group_rollup(query, :alias) do
    from(u in query,
      group_by: u.alias_name,
      order_by: [desc: sum(u.tokens_in) + sum(u.tokens_out)],
      select: %{alias: u.alias_name}
    )
    |> with_metrics()
  end

  defp group_rollup(query, :capability) do
    from(u in query,
      group_by: u.capability,
      order_by: [desc: sum(u.tokens_in) + sum(u.tokens_out)],
      select: %{capability: u.capability}
    )
    |> with_metrics()
  end

  defp group_rollup(query, :client_key) do
    from(u in query,
      left_join: k in assoc(u, :client_key),
      group_by: [u.client_key_id, k.name],
      order_by: [desc: sum(u.tokens_in) + sum(u.tokens_out)],
      select: %{client_key_id: u.client_key_id, client_key: k.name}
    )
    |> with_metrics()
  end

  # Percentiles come from Postgres rather than a fold in Elixir so the rollup
  # never loads the record set into memory.
  defp with_metrics(query) do
    from(u in query,
      select_merge: %{
        requests: count(u.id),
        errors: filter(count(u.id), u.outcome == :error),
        timeouts: filter(count(u.id), u.outcome == :timeout),
        fallbacks: filter(count(u.id), u.fallback_used == true),
        tokens_in: coalesce(sum(u.tokens_in), 0),
        tokens_out: coalesce(sum(u.tokens_out), 0),
        cost: sum(u.cost),
        p50_latency_ms: fragment("percentile_disc(0.5) WITHIN GROUP (ORDER BY ?)", u.latency_ms),
        p95_latency_ms: fragment("percentile_disc(0.95) WITHIN GROUP (ORDER BY ?)", u.latency_ms)
      }
    )
  end

  # `sum(cost)` is null when no priced record fell in the window; report 0.0 so
  # an accumulating consumer doesn't have to special-case an empty bucket.
  defp cast_rollup(row), do: Map.update(row, :cost, 0.0, &to_float/1)

  ## ------------------------------------------------------------------
  ## Shared helpers
  ## ------------------------------------------------------------------

  # Newest record per (deployment, outcome) in one pass — the last time real
  # inference succeeded or failed on a deployment. Distinct from probe health:
  # the prober's GET /models answers while a slot is still warming, so this is
  # the readiness signal and the probe is only liveness.
  defp deployment_activity do
    # Newest success and newest failure per deployment.
    #
    # Deliberately *not* `DISTINCT ON` over the whole table. That has to sort
    # every row that has a deployment before it can take the first of each
    # group — on prod, a seq scan of 85k rows and a 3.5 MB sort of 51k of them
    # to return 10, at 81ms, growing with the retention window. Deployments are
    # a handful, so seek straight to the newest row for each
    # (deployment, outcome) pair instead: each is one backward index scan on
    # `usage_records_deployment_outcome_inserted_at_index`, and the cost stops
    # tracking the table's size (0.26ms on the same data).
    #
    # Raw SQL because the lateral-over-a-values-list is the whole point here and
    # Ecto can't express it without more ceremony than it saves.
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT d.id, o.outcome, x.inserted_at, x.error_code
      FROM deployments d
      CROSS JOIN unnest(ARRAY['success','error','timeout']) AS o(outcome)
      JOIN LATERAL (
        SELECT u.inserted_at, u.error_code
        FROM usage_records u
        WHERE u.deployment_id = d.id AND u.outcome = o.outcome
        ORDER BY u.inserted_at DESC
        LIMIT 1
      ) x ON TRUE
      """)

    rows
    |> Enum.map(fn [deployment_id, outcome, at, error_code] ->
      %{
        deployment_id: deployment_id,
        outcome: String.to_existing_atom(outcome),
        at: at,
        error_code: error_code
      }
    end)
    |> Enum.reduce(%{}, fn row, acc ->
      entry = Map.get(acc, row.deployment_id, %{})

      entry =
        case row.outcome do
          :success -> Map.put(entry, :last_success_at, row.at)
          _failure -> failure_entry(entry, row)
        end

      Map.put(acc, row.deployment_id, entry)
    end)
  end

  # `:error` and `:timeout` share the "last failure" slot; keep the newer.
  defp failure_entry(entry, row) do
    if entry[:last_error_at] && NaiveDateTime.compare(entry[:last_error_at], row.at) == :gt do
      entry
    else
      Map.merge(entry, %{
        last_error_at: row.at,
        last_error_code: row.error_code || to_string(row.outcome)
      })
    end
  end

  # One control call per host, concurrently and with a hard deadline: a host that
  # is down must degrade the inventory to nil, not stall the whole snapshot.
  defp inventories(agents) do
    agents
    |> Task.async_stream(
      fn agent ->
        case Control.inventory(agent, req_options: [receive_timeout: @inventory_timeout_ms]) do
          {:ok, models} -> {agent.id, models}
          {:error, _reason} -> {agent.id, nil}
        end
      end,
      timeout: @inventory_timeout_ms + 1_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {id, models}} -> [{id, models}]
      {:exit, _reason} -> []
    end)
    |> Map.new()
  end

  defp inventory_index(nil), do: %{}
  defp inventory_index(models), do: Map.new(models, &{&1["id"], &1})

  defp inventory_entry(model) do
    %{
      id: model["id"],
      family: model["family"],
      quantization: model["quant"],
      revision: model["revision"],
      size_bytes: model["size_bytes"],
      path: model["path"]
    }
  end

  # `since` is an id cursor when it parses as an integer, else a timestamp.
  defp apply_since(query, nil), do: query

  defp apply_since(query, since) when is_integer(since),
    do: from(q in query, where: q.id > ^since)

  defp apply_since(query, %DateTime{} = since),
    do: apply_since(query, DateTime.to_naive(since))

  defp apply_since(query, %NaiveDateTime{} = since),
    do: from(q in query, where: q.inserted_at > ^since)

  defp apply_since(query, since) when is_binary(since) do
    case parse_since(since) do
      nil -> query
      parsed -> apply_since(query, parsed)
    end
  end

  @doc """
  Parse a `since` parameter: an integer id cursor, or an ISO 8601 timestamp.
  Returns `nil` for anything unparseable so a bad cursor reads the full window
  rather than silently returning nothing.
  """
  @spec parse_since(term()) :: integer() | NaiveDateTime.t() | nil
  def parse_since(nil), do: nil
  def parse_since(value) when is_integer(value), do: value

  def parse_since(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> parse_timestamp(value)
    end
  end

  def parse_since(_value), do: nil

  defp parse_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_naive(datetime)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> naive
          _ -> nil
        end
    end
  end

  defp cursor_of(since) when is_integer(since), do: since
  defp cursor_of(since) when is_binary(since), do: cursor_of(parse_since(since))
  defp cursor_of(_since), do: nil

  defp next_cursor([], since), do: cursor_of(since)
  defp next_cursor(events, _since), do: events |> List.last() |> Map.fetch!(:id)

  defp split_page(rows, limit) do
    if length(rows) > limit, do: {Enum.take(rows, limit), true}, else: {rows, false}
  end

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, _} -> clamp_limit(n)
      :error -> @default_limit
    end
  end

  defp clamp_limit(_limit), do: @default_limit

  defp status_rank(:up), do: 0
  defp status_rank(:unknown), do: 1
  defp status_rank(_down), do: 2

  # ETS keeps monotonic timestamps (immune to clock changes); consumers need wall
  # clock. Convert via the observed age rather than storing both.
  defp monotonic_to_wall(nil), do: nil

  defp monotonic_to_wall(checked_at) do
    age = System.monotonic_time(:millisecond) - checked_at
    DateTime.utc_now() |> DateTime.add(-age, :millisecond) |> DateTime.truncate(:second)
  end

  defp sort_by_name(providers), do: Enum.sort_by(providers, & &1.name)
  defp sort_by_model(deployments), do: Enum.sort_by(deployments, & &1.model_name)

  defp basename(name) when is_binary(name), do: Path.basename(name)
  defp basename(name), do: name

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
  defp to_float(_nil_or_other), do: 0.0

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
