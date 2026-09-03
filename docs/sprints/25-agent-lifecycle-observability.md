# Sprint 25 — Agent lifecycle observability

> **Status: planned.** Branch `sprint/25-agent-lifecycle-observability`. Airo
> only — no `airo_agent` change, deployable to prod on its own.

Companion to
[DESIGN-agent-lifecycle-and-roles.md](../design/DESIGN-agent-lifecycle-and-roles.md)
§2 (S25 decisions) and §5 (event catalogue). Builds on
[DESIGN-agent-management.md](../design/DESIGN-agent-management.md) (S17) and
the settings/hysteresis pattern from S24.

> **Goal (one sentence):** make every agent connect, drop, and silence visible —
> as a telemetry event, a `host_events` row, a fleet-wide broadcast, and a
> `/metrics` gauge — so that S26 can be verified against prod and so the
> dashboards stop polling for facts the channel already knows.

> **Why now.** Five hosts push to prod over a channel whose only liveness signal
> is Presence. `agents.last_seen_at` is written on every register and never
> read for staleness; a host whose agent hangs with the socket open looks
> healthy forever at the host level. There is no `:telemetry.execute` in the
> codebase, no line in the log when a host connects or drops, and no record
> that would answer "when did sparky last disconnect and for how long".
> `HomeLive` and `AgentLive` each subscribe per host and *also* poll every 10 s
> because there is no fleet-level topic. S26 will connect a second airo to the
> same agents; without this sprint there is no way to tell whether that
> disturbed prod.

---

## What's there now

- `AiroWeb.AgentChannel` — `:after_join` tracks Presence; `terminate/2` calls
  `Ingest.host_down/1`. No telemetry, no log line, no event row on either.
- `Airo.Agents.Ingest.register/2` — upserts the `agents` row (`last_seen_at`
  refreshed), slots → providers, `SlotState`, provenance, health. Runs every
  10 s per host. Also makes a **synchronous** `Control.inventory/1` HTTP call on
  every register and every slot push (`inventory_index/1`).
- `Airo.Health` — deployment snapshots decay to `:unknown` after 90 s. That is
  the only aging anywhere, and it is per deployment, not per host.
- `Airo.Health.Prober` skips agent-managed providers. Push is the sole health
  source for slots.
- `GET /metrics` — `airo_host_last_seen_timestamp_seconds` is the only host
  liveness proxy. No online/offline series.
- `health_events` — status transitions for deployments, `source` includes
  `:agent`. Nothing equivalent for hosts.
- `AiroWeb.Telemetry` — stock generator module; reporter child commented out.
- `HomeLive` (`subscribe_agents/2`, 10 s tick) and `AgentLive`
  (`subscribe_presence/1`, `@refresh_ms 10_000`) — per-host subscriptions with
  a poll fallback for roster drift.

## Design

Decisions are fixed in the design note; this is the implementation shape.

### 1. `Airo.Agents.Lifecycle` — the choke point

```elixir
Lifecycle.transition(host_id, kind, opts)
# kind :: :connected | :disconnected | :stale | :recovered
#       | :version_changed | :control_url_changed
# opts :: reason: String.t(), meta: map(), agent: %Agent{} | nil
```

In order: insert `host_events`; mirror `connected`/`disconnected`/`stale`/
`recovered` into `log_events` via `Airo.Logs.record/1` (off the hot path, same
Task.Supervisor S14 uses); `Phoenix.PubSub.broadcast(Airo.PubSub, "agents",
{:agent_event, %{host_id: host_id, kind: kind}})`; `:telemetry.execute/3`.
Failures in the mirror or broadcast are logged and swallowed — recording must
never fail an ingest.

Callers: `AgentChannel` (`connected`, `disconnected`), `Ingest.register/2`
(`version_changed`, `control_url_changed`, `recovered`), `Liveness` (`stale`).

### 2. Change detection in `Ingest.register/2`

`register` is a heartbeat. The upsert already compares against the existing
row; extend it to return what changed (`version`, `control_url`) and call
`transition/3` only for those. The first register after a connect is *not* an
event of its own — `connected` already fired from the channel, and the
register's metadata is attached to it by `Lifecycle` reading the fresh row.

### 3. `Airo.Agents.Liveness` — the sweeper

A GenServer under the application supervisor, ticking every 15 s
(configurable for tests). For every host present in Presence: if
`now - last_seen_at > agent_stale_after_ms` and the host is not already
stale → `transition(host_id, :stale, reason: "no register for #{ms}ms")`
and mark each of its deployments `:unknown` through
`Health.mark_deployment/4` (`source: :agent, reason: "agent_stale"`). Stale
hosts are held in the `:airo_health` ETS table (existing runtime store), not in
Postgres — stale is runtime state and must reset on boot. `Ingest.register/2`
clears the flag and emits `recovered` when a stale host registers again.

Hosts **absent** from Presence but still holding `SlotState` (a missed
`terminate`, or state left over from before an airo restart — the ETS is empty
after a restart, so this is the missed-terminate case only) are treated as
disconnected: the sweeper calls `Ingest.host_down/1`, which already does the
right thing.

### 4. Threshold on `/admin/settings`

`site_settings.agent_stale_after_ms`, default 45 000, validated `>= 20_000`
(two heartbeats — below that every GC pause is an incident). Rendered beside
`down_after_failures`, same form.

### 5. Fleet topic consumers

`HomeLive` subscribes once to `"agents"` on mount and drops `subscribe_agents/2`
and the `subscribed` MapSet. On any `{:agent_event, _}` it re-derives the
online/stale flags; on `connected`/`disconnected` it re-runs the overview
query. The 10 s tick becomes a 60 s safety net. `AgentLive` keeps its per-host
`agent_slots:` subscription (that is per-host by nature) and adds `"agents"`
for the host's own lifecycle rows. The agents index page, if it lists hosts,
follows `HomeLive`.

Stale renders distinctly from offline: online, **stale** (amber, "silent 47 s"),
offline. Same three states on the `HomeLive` ring cards.

### 6. `/metrics`, `/v1/serving`, telemetry metrics

- `airo_host_online{host_id}` — 1 if in Presence.
- `airo_host_stale{host_id}` — 1 if the Liveness flag is set.
- `/v1/serving` per-host gains `"stale": bool` and `"role"` (S26 fills it;
  S25 emits `"controller"` for every host so the field is stable).
- `GET /v1/serving/hosts?since=<iso8601>` — `host_events` after `since`,
  management scope, same shape conventions as `/v1/serving/health`.
- `AiroWeb.Telemetry.metrics/0` gains `counter("airo.agent.join.count", tags:
  [:host_id])`, `counter("airo.agent.leave.count", tags: [:host_id])`,
  `counter("airo.agent.slot.count", tags: [:host_id, :status])`,
  `summary("airo.agent.control.stop.duration", unit: {:native, :millisecond},
  tags: [:op])`. Visible in LiveDashboard in dev; nothing else consumes them
  yet.

### 7. `Control` span

Wrap the body of `Control.request/5` in `:telemetry.span([:airo, :agent,
:control], %{host_id: ..., op: ...}, fn -> ... end)`. `op` is the calling
function's name (`:load`, `:unload`, `:inventory`, `:refresh_inventory`,
`:slots`, `:gpu`). This is a measurement seam only — no behaviour change. It
will quantify the per-heartbeat `GET /inventory` cost that today is invisible.

### 8. `/admin/agents/:id` timeline

A "Host events" card below the slots: last 50 `host_events` for the host,
newest first, kind + reason + meta summary, rendered through
`AiroWeb.Time.format_at/2`. Live-updates from the `"agents"` topic.

## Deliverables

1. `host_events` migration + `Airo.Agents.HostEvent` schema + Oban prune
   (30-day default, same worker pattern as `log_events`).
2. `Airo.Agents.Lifecycle.transition/3` and the six telemetry events from the
   design note's catalogue, wired at the listed call sites.
3. `Airo.Agents.Liveness` sweeper + stale flag in the runtime store +
   `recovered` on register; deployments marked `:unknown` while stale.
4. `site_settings.agent_stale_after_ms` on `/admin/settings`.
5. Fleet topic `"agents"`; `HomeLive` and `AgentLive` subscribe to it; the
   per-host Presence subscription bookkeeping in `HomeLive` deleted; polls
   demoted to 60 s.
6. `/metrics` online + stale gauges; `/v1/serving` `stale` + `role` fields;
   `GET /v1/serving/hosts?since=`.
7. `Control.request/5` telemetry span.
8. Structured `Logger.info`/`warning` on connect and disconnect with
   `host_id`, `version`, `control_url`, `reason` as metadata.
9. Host events timeline on `/admin/agents/:id`; stale state rendered on
   `HomeLive` and `AgentLive`.

## Tests

- Channel join writes `connected` + emits `[:airo, :agent, :join]`
  (`:telemetry_test.attach_event_handlers/2`); leave writes `disconnected` +
  emits `:leave`; both mirrored into `log_events`.
- Register with unchanged metadata writes **no** `host_events` row; a changed
  `version` writes exactly one `version_changed`.
- Liveness: with `agent_stale_after_ms` at 100 and the tick driven manually, a
  present host with an old `last_seen_at` becomes stale (event, gauge,
  deployments `:unknown`); a register clears it with `recovered`; a host absent
  from Presence with `SlotState` gets `host_down/1`.
- Fleet topic: a subscriber to `"agents"` receives `{:agent_event, %{kind:
  :connected}}` on join; `HomeLive` re-renders online state without its tick.
- `/metrics` exposes both gauges with the right values; `/v1/serving/hosts`
  filters by `since` and respects management scope.
- `Control` span fires `start`/`stop` with `op` set, using the S23
  `stub_control/1` seam.
- Settings: threshold persists, and a value below 20 000 is rejected.

## Non-goals

- Alerting. Nothing notifies anyone.
- Prometheus/Grafana. `/metrics` is the contract.
- Fixing the per-heartbeat `GET /inventory`. S25 measures it; the fix is a
  follow-up with numbers attached.
- Roles. S25 emits `role: "controller"` everywhere as a placeholder; S26 owns
  the concept.
- Any `airo_agent` change.

## Risks

- **Event volume from a flapping host.** A host reconnecting every second would
  write two rows a second. Mitigation: `host_events` is insert-only and pruned,
  and the `log_events` mirror is the same volume `health_events` already
  produces for such a host. If it bites, coalesce repeated
  connect/disconnect pairs within a window — not pre-emptively.
- **Stale false positives on a loaded host.** A 45 s silence on a box mid-load
  is plausible under vLLM startup. The threshold is a setting for this reason,
  and stale only demotes preference (deployments `:unknown`), it never removes
  a deployment — same safety argument S24 relied on.
- **Replacing per-host subscriptions changes `HomeLive` update timing.** The
  60 s tick stays as a net; the acceptance step below checks the page updates
  on a real disconnect without it.

## Acceptance

- Deployed to prod. Restart the agent on `pvegpu`: `/admin/agents/:id` shows a
  `disconnected` then `connected` pair with timestamps in the configured zone;
  `GET /v1/serving/hosts?since=` returns both; `airo_host_online{host_id="pvegpu"}`
  flips 1 → 0 → 1 in `/metrics`; `HomeLive` on prod updates the ring card
  without waiting for a tick.
- `kill -STOP` the agent on `pvegpu` (socket stays open, heartbeats stop):
  within `agent_stale_after_ms` + one sweep, `stale` is recorded, the gauge is
  1, and its deployments read `:unknown` in `/v1/serving`. `kill -CONT`:
  `recovered` within one heartbeat.
- Suite green; `mix joby_kit.lint` clean; `mix precommit` green.
