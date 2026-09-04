# Airo — Agent lifecycle observability & observer airos (S25 / S26)

Companion to [DESIGN-agent-management.md](./DESIGN-agent-management.md) (S17,
the control plane). This note **extends** S17's §2 fixed decisions; it reverses
none of them. S25 is airo-only and deployable on its own. S26 touches both
`airo` and `airo_agent` and depends on S25 for its verification path.

## 0. The problem in one paragraph

Every agent pushes to exactly one airo: `AIRO_SOCKET_URL` is a single value and
`AiroAgent.Notifier.Supervisor` starts a single `Notifier.Channel`. All five
fleet hosts (`forge`, `jobycorp`, `pvegpu`, `sparky`, `sparky2`) point at prod.
Airo commands an agent by HTTP `POST` to its `control_url`, gated by an optional
shared bearer token that is **unset fleet-wide**. Two consequences. First, the
dev airo on the workstation sees no hosts at all — an empty dashboard and no way
to exercise agent-facing code against a real host once the fleet is on prod.
Second, prod's own view of the fleet is unobserved: no telemetry events, no
record of a host connecting or dropping, and nothing that ages out a host that
goes silent without closing its socket. Underneath both is a missing concept:
nothing distinguishes *an airo that may look* from *the airo that may command*.

## 1. What exists (verified 2026-09-03)

| Piece | Where | State |
|---|---|---|
| Agent socket + channel | `lib/airo_web/channels/agent_socket.ex`, `agent_channel.ex` | Join needs `host_id` + `token`; unset token accepts anyone. Messages in: `register` (10 s heartbeat), `slot`. Message out: `resync` only. |
| Ingest | `lib/airo/agents/ingest.ex` | `register`/`slot` → `agents` row, `SlotState` ETS, providers, provenance, deployment health. `host_down/1` on channel `terminate/2`. |
| Liveness | Presence on `agent:<host_id>` | The **only** liveness signal. `agents.last_seen_at` refreshes on register and is never aged. `SlotState.updated_at` is never aged. Deployment health decays to `:unknown` after 90 s (`Airo.Health`). |
| Control | `lib/airo/agents/control.ex` | HTTP to `control_url`, bearer = `agent_token`. No notion of who is allowed to call. |
| PubSub | `agent_slots:<host_id>`, `agent:<host_id>` | Per-host only. `HomeLive` and `AgentLive` subscribe per host as hosts appear **and** poll every 10 s for roster drift. No fleet-wide topic. |
| Observability | `GET /metrics`, `GET /v1/serving`, `/v1/serving/health?since=`, `health_events` | Rich for slots and deployments. No `:telemetry.execute` anywhere; no host online gauge; no host-level event table; no structured connect/disconnect log line. LiveDashboard is dev-only. |
| Agent side | `airo_agent/lib/airo_agent/notifier/{channel,supervisor}.ex`, `config/runtime.exs` | One `Channel` child, `publish/1` via `Process.whereis(__MODULE__)`. Reconnect backoff caps at 10 s. `AIRO_AGENT_TOKEN` empty-string trap documented in `deploy/hosts/forge.env`. |

## 2. Fixed decisions (do not re-litigate)

### S25 — lifecycle observability

- **One choke point.** Every host lifecycle transition passes through
  `Airo.Agents.Lifecycle.transition/3`, which does four things in order: writes
  a `host_events` row, mirrors an operator-relevant subset into `log_events`,
  broadcasts on the fleet topic, and executes a `:telemetry` event. Nothing
  else writes `host_events`. This is what makes the four consumers agree.
- **Transitions only, never heartbeats.** `register` arrives every 10 s per
  host. It updates `last_seen_at` and a telemetry counter; it writes a
  `host_events` row only when something changed — first register after
  connect, `version` changed, `control_url` changed, `role` changed (S26).
- **Stale is a state, derived from two signals.** *Connected* = Presence has
  the host (`Liveness.online?/1` is the one reader core code uses). *Stale* =
  connected **and** `last_seen_at` older than `agent_stale_after_ms`. A
  `Liveness` sweeper evaluates every host on a **5 s** tick (15 s missed the
  window on prod on 2026-09-04: Phoenix closes an idle socket 60 s after its
  last frame, so a frozen agent is observably stale only for ~45–50 s of
  silence before it becomes a disconnect);
  entering stale writes `stale`, the next register writes `recovered`. Stale
  also marks the host's deployments `:unknown` through the existing
  `Health.mark_deployment/4` path (`source: :agent, reason: "agent_stale"`),
  so routing preference follows. Recovery is immediate on one register,
  matching S24's "hysteresis down, none up".
- **The threshold is a setting, not an attribute.** `agent_stale_after_ms`
  lives on `/admin/settings` beside `down_after_failures` (S24 pattern).
  Default 45 000 ms — four and a half heartbeats.
- **One fleet topic, `"agents"`.** Message shape
  `{:agent_event, %{host_id: String.t(), kind: atom()}}`. Per-host topics
  remain for per-host pages; roster-level subscribers (`HomeLive`, the agents
  index) subscribe once to `"agents"` and drop the per-host bookkeeping.
- **`/metrics` stays the external contract.** Two new gauges,
  `airo_host_online{host_id}` and `airo_host_stale{host_id}`. No PromEx, no
  OpenTelemetry, no new dependency. Telemetry events also feed
  `AiroWeb.Telemetry.metrics/0` so LiveDashboard shows them in dev.
- **`host_events` is insert-only**, shaped like `health_events`, read by
  `GET /v1/serving/hosts?since=` (mirroring `/v1/serving/health?since=`) and
  by a timeline on `/admin/agents/:id`. Pruned by the existing Oban prune
  pattern, 30-day default.
- **Mirror to `log_events`:** `connected` (info), `disconnected` (warning),
  `stale` (warning), `recovered` (info). Version and control-URL changes stay in
  `host_events` only — S24 established that `log_events` is what an operator
  reads, and a version bump is not an incident.

### S26 — observer airos

- **One controller per agent, N observers, encoded in the config shape.**
  `AIRO_SOCKET_URL` keeps its meaning and is the controller. A new
  `AIRO_OBSERVER_SOCKET_URLS` (CSV) lists observers. There is no way to
  configure two controllers, and every existing host file is valid unchanged.
- **Role travels with the connection.** Each `Notifier.Channel` carries its
  role as a join param and in the `register` payload (`agent.role`). Airo
  persists `agents.role` (`:controller | :observer`); a missing role is
  `:controller`, so pre-S26 agents interoperate.
- **An observer airo ingests everything.** `SlotState`, providers, provenance,
  GPU telemetry, deployment health — the full push pipeline runs. It may route
  inference to the slots: the data path goes straight to `base_url` and never
  touched the agent (S17's cardinal rule). Only **host-mutating control** is
  refused: `POST /load` and `POST /unload`. Reads, `resync`, and
  `POST /inventory/refresh` (an idempotent rescan) are allowed.
- **Enforcement is airo-side in v1.** `Airo.Agents.Control.load/4` and
  `unload/3` return `{:error, :observer_role}` when `agent.role == :observer`;
  `AgentLive` disables those actions with an observer badge. Agent-side
  enforcement needs to identify the caller, which needs per-airo tokens — a
  separate sprint. Stated plainly: on this LAN any `curl` can already
  `POST /load` to an agent; S26 does not change that threat model, it prevents
  the dev airo from doing so by accident or bug.
- **Dev reachability is an operator prerequisite, not code.** The agent is the
  client; the workstation must be reachable from the GPU hosts. That means a
  reserved DHCP lease and a Pi-hole DNS name for the workstation. The only code
  change is that `config/dev.exs` binds `0.0.0.0` when `AIRO_DEV_BIND=lan`
  and loopback otherwise.
- **Observer connections back off harder.** Reconnect cap 60 s for observer
  endpoints (controller stays at 10 s). A laptop that is closed should not
  have five GPU hosts retrying it every ten seconds.
- **Role is static config in v1.** Changing a host's role means editing its
  env file and redeploying the agent. Runtime role flips ("lease this host to
  dev for an hour") are a follow-up, and they need agent-side enforcement
  first.

## 3. Data model

```
host_events
  id            bigserial
  agent_id      references agents (nullable — a host may connect before its row exists)
  host_id       text        not null
  kind          text        not null   -- connected | disconnected | stale | recovered
                                       -- | version_changed | control_url_changed | role_changed
  reason        text                   -- e.g. "agent_disconnected", "no register for 47s"
  meta          jsonb                  -- {version, control_url, role, previous: {...}}
  inserted_at   timestamp   not null
  index (host_id, inserted_at)

agents
  + role        text  not null default 'controller'   -- Ecto.Enum [:controller, :observer]

site_settings
  + agent_stale_after_ms  integer not null default 45000
```

## 4. Wire contract changes (agent ↔ airo)

| Where | Before | After |
|---|---|---|
| Socket connect params | `host_id`, `token` | + `role` (optional; absent ⇒ `controller`) |
| `register` payload `agent` | `control_url`, `version`, `gpu` | + `role` |
| Presence meta | `online_at` | + `role`, `version` |
| Everything else | — | unchanged |

Old agents against new airo: role defaults to controller. New agents against
old airo: the extra param and key are ignored. No flag day.

## 5. Telemetry event catalogue

| Event | Measurements | Metadata | Emitted from |
|---|---|---|---|
| `[:airo, :agent, :join]` | `%{count: 1}` | `host_id`, `version`, `control_url` (role in S26) | `AgentChannel.handle_info(:after_join)` via `Lifecycle` |
| `[:airo, :agent, :leave]` | `%{count: 1}` | `host_id`, `exit` (role in S26) | `AgentChannel.terminate/2` via `Lifecycle` |
| `[:airo, :agent, :register]` | `%{count: 1, slots: n}` | `host_id`, `role` | `Ingest.register/2` |
| `[:airo, :agent, :slot]` | `%{count: 1}` | `host_id`, `port`, `status`, `reason` | `Ingest.slot/2` |
| `[:airo, :agent, :stale]` / `[:airo, :agent, :recovered]` | `%{count: 1, silent_ms: ms}` | `host_id` | `Liveness` sweeper / `Liveness.registered/1` |
| `[:airo, :agent, :changed]` | `%{count: 1}` | `host_id`, `kind` (`version_changed` \| `control_url_changed`), `field`, `from`, `to` | `Ingest.register/2` via `Lifecycle` |
| `[:airo, :agent, :control, :start \| :stop \| :exception]` | span (`duration`) | `host_id`, `op` (`load`, `unload`, `inventory`, …), `status` | `Control.request/5` via `:telemetry.span/3` |

The `control` span is the one that will show what `Ingest.inventory_index/1`
costs today — a synchronous `GET /inventory` on **every** register and slot
push, per connected airo. S25 measures it; fixing it (cache by `revision` or
move off the register path) is a follow-up once the numbers are in.

## 6. Non-goals (both sprints)

- Alerting or notifications of any kind.
- Deploying Prometheus or Grafana. `/metrics` is the contract; a scraper is an
  infra decision for another day.
- OpenTelemetry or PromEx.
- Agent-side authorisation per airo (per-airo tokens). Needed before roles can
  be trusted against a hostile caller; not needed to keep dev honest.
- Runtime role changes or host leases.
- Erlang distribution between dev and prod. Separate DBs, separate Presence,
  separate PubSub — clustering them would blur the one boundary this design
  exists to draw.
- Any cross-airo coordination. Two airos never talk to each other; each holds
  its own view fed by its own connection to the agent.

## 7. Resolved question — role on the join, or an allowlist on airo?

**On the join.** Three reasons. The agent is the thing being protected, so the
agent's configuration is where the grant should be visible — one `cat
/etc/airo-agent.env` answers "who may command this box". It gives every airo the
same code path: read the role you were granted, behave accordingly. And it is the
shape agent-side enforcement will need later: the agent already knows the role
per connection, and per-airo tokens can be attached to those same entries. An
airo-side allowlist would have meant a dev airo deciding for itself that it is an
observer, which is exactly the self-certification this design is trying to
remove.

What PAIR (NVIDIA's Personal AI Router) does here is the same idea with more
ceremony: a node keeps its own membership record, established by a PIN
exchange. On a LAN with Traefik DNS the PIN buys nothing; the *node-held
record* is the part worth copying, and `AIRO_OBSERVER_SOCKET_URLS` is that
record.
