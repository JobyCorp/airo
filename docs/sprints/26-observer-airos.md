# Sprint 26 — Observer airos (one controller, N observers per agent)

> **Status: complete (S26), merged to `main` in both repos 2026-09-04; pilot
> proven on `pvegpu`, rollout to the remaining hosts pending.** airo: 603
> tests (+8 over S25), precommit green, `joby_kit.lint` 16. airo_agent: 168
> tests green on macOS (the `vllm-slot` wrapper was made bash 3.2 safe along
> the way).

> **Decisions taken while building:** `role` is a third identity field beside
> `version` and `control_url`, so a role flip is a `role_changed` host event
> through the same S25 path. A pre-S26 agent sends no role and the row keeps
> whatever it holds. The socket refuses an unknown role outright rather than
> defaulting it — a typo must not silently mint a controller. Channel clients
> are named in a `Registry` by URI and `publish/1` fans out over
> `Registry.select`, so tests can start several without the supervisor. The
> observer-tooltip "controller is …" from the plan was dropped: the agent does
> not report its controller's host, and a wrong guess is worse than none.

Companion to
[DESIGN-agent-lifecycle-and-roles.md](../design/DESIGN-agent-lifecycle-and-roles.md)
§2 (S26 decisions), §4 (wire contract), §7 (why the role rides the join).

> **Goal (one sentence):** let an agent push its state to more than one airo,
> with exactly one of them allowed to command it, so the dev airo on the
> workstation sees the real fleet live and can route to it without ever being
> able to load or unload a model.

> **Why now.** With the fleet pointed at prod, dev has no hosts. Every
> agent-facing feature since S17 — the control plane, capacity, provenance,
> the config modal, VRAM validation — can only be exercised against prod or
> against a stub. S23 had to invent a Presence helper just to render the online
> half of one page. Meanwhile the agent's single socket URL and single channel
> child are the only things standing between "point dev at the agents too" and
> "two airos fighting over the same GPU". The fix is to make that second
> connection possible and make its role explicit.

---

## What's there now

**Agent side (`airo_agent`)**

- `config/runtime.exs` — `AIRO_SOCKET_URL` is a single value; `notifier:` is
  `Channel` iff set, else `Log`.
- `Notifier.Supervisor` — `children = [AiroAgent.Notifier.Channel]`. One child,
  named by module.
- `Notifier.Channel.publish/1` — `Process.whereis(__MODULE__)`; one process.
  Join params `host_id` + `token`; `register` payload `agent: %{control_url,
  version, gpu}`; `reconnect_after_msec: [1_000, 2_000, 5_000, 10_000]`.
- Five host files under `deploy/hosts/` all carry
  `AIRO_SOCKET_URL=wss://llm.local.joby.gg/agent`. `AIRO_AGENT_TOKEN` is unset
  on every host (the empty-string trap is documented in `forge.env`).

**Airo side**

- `AgentSocket.connect/3` reads `host_id` + `token`, ignores anything else.
- `agents` table has no role. `Control` has no notion of permission.
- `config/dev.exs` binds `127.0.0.1`. A GPU host cannot reach it.
- Both airos would run `Ingest` fully against the same pushes, each into its
  own database — no shared state, no collision, but also double the
  per-heartbeat `GET /inventory` load on each agent (measured by S25's span).

## Design

### Agent side

1. **Endpoint list.** `runtime.exs` builds
   `airo_endpoints: [%{uri: ..., role: :controller}, %{uri: ..., role:
   :observer}, ...]` from `AIRO_SOCKET_URL` (controller, at most one) and
   `AIRO_OBSERVER_SOCKET_URLS` (CSV, observers). An observer URL equal to the
   controller URL is dropped with a warning. `notifier:` is `Channel` iff the
   list is non-empty. **Unset vs empty:** an empty `AIRO_OBSERVER_SOCKET_URLS`
   is treated as unset — the `AIRO_AGENT_TOKEN` trap must not be repeated.
2. **One `Channel` per endpoint.** `Notifier.Supervisor` starts one
   `Notifier.Channel` child per entry, registered in a `Registry`
   (`AiroAgent.Notifier.Registry`, keys `:duplicate`, key `:airo_channel`) so
   `publish/1` becomes `Registry.dispatch/3` over every live channel. Each
   child gets `uri`, `role`, and its own reconnect list — observers use
   `[1_000, 5_000, 15_000, 60_000]`.
3. **Role on the wire.** `socket_uri/1` appends `role=<role>` to the query;
   `agent_meta/1` adds `role:` to the `register` payload. Log lines include
   the role and the host part of the URI so two connections are tellable
   apart.
4. **Supervisor budget.** `max_restarts: 100, max_seconds: 10` was sized for
   one child; with N children the same budget is shared, which is the right
   call — the firewall protects serving from *all* channels, not each channel
   from the others. Documented in the moduledoc.
5. **Tests.** Supervisor starts N children from config and none when the list
   is empty; `publish/1` reaches every child (two `test_mode?` channels);
   `register` payload carries `role`; the observer reconnect list is applied;
   empty CSV ⇒ no observers.

### Airo side

6. **Schema.** `agents.role` — `Ecto.Enum, values: [:controller, :observer],
   default: :controller`. Migration backfills nothing (default covers it).
7. **Socket + channel.** `AgentSocket.connect/3` reads optional `role`,
   validates against the enum (anything else ⇒ `:error`), assigns it.
   `AgentChannel` puts `role` and `version` in Presence meta. Join topic and
   token handling unchanged.
8. **Ingest.** `agent_attrs/1` reads `payload["agent"]["role"]`, default
   `"controller"`. A change writes `role_changed` through S25's `Lifecycle`.
9. **Control guard.** `Control.load/4` and `unload/3` check `agent.role`
   first and return `{:error, :observer_role}` without a request. `inventory`,
   `refresh_inventory`, `slots`, `gpu`, and the `resync` broadcast are
   unaffected. The guard lives in `Control`, not the LiveView, so `iex` and
   any future caller get the same answer.
10. **UI.** `/admin/agents/:id`: a role chip beside the online state; Load,
    Configure, Swap, Unload disabled when observer with tooltip "This airo
    observes this host; controller is <controller host from Presence meta if
    known, else unknown>". Resync and Refresh inventory stay enabled.
    `HomeLive` ring cards show the chip. The agents index lists the role.
    Wrappers throughout — the chip is the kit's `<.badge>`
    (`JobyKit.CoreComponents.badge/1`); `mix joby_kit.lint` gates it.
11. **`/v1/serving`.** `role` field (S25 placeholder) becomes real.
12. **Dev bind.** `config/dev.exs`: `ip: if(System.get_env("AIRO_DEV_BIND") ==
    "lan", do: {0, 0, 0, 0}, else: {127, 0, 0, 1})`. Default behaviour
    unchanged. `check_origin: false` already holds in dev.

### Operator prerequisites (not code, but on the checklist)

- **Done (verified 2026-09-03):** `jobybook.local.joby.gg` is a static A
  record in Pi-hole (`192.168.68.2`) for the workstation's reserved DHCP
  address, and resolves from the GPU hosts. The reservation is against the
  Mac's *private* Wi-Fi address, so the one remaining check is that the
  network's private-address mode is Fixed, not Rotating.
- `AIRO_DEV_BIND=lan` in the dev shell that runs `mix phx.server` (port 4004).
- Pilot on **`pvegpu`** first (decided 2026-09-03): zero requests in the
  trailing seven days, no alias bound, and nothing resident since
  2026-09-02 06:57 UTC, so the agent restart drains nothing. SSH from the workstation and the
  QEMU guest agent on VM 201 (pve) were both verified working on
  2026-09-03, so `bin/deploy.sh pvegpu` can run from here. Add
  `AIRO_OBSERVER_SOCKET_URLS=ws://jobybook.local.joby.gg:4004/agent` to
  `deploy/hosts/pvegpu.env`, `bin/deploy.sh pvegpu`. Then the rest.

## Deliverables

**`airo_agent`**

1. Endpoint list in `runtime.exs` (`AIRO_OBSERVER_SOCKET_URLS`), README env
   table row, `deploy/hosts/example.env` line (commented, with the unset/empty
   note).
2. `Notifier.Registry` + N-child `Notifier.Supervisor`; `publish/1` fan-out;
   per-endpoint role and reconnect list.
3. `role` in join params and `register` payload.
4. Tests listed under design item 5. `DESIGN.md` gains a short "Multiple
   airos" paragraph pointing at this sprint's design note.

**`airo`**

5. `agents.role` migration + schema + `Ingest` read + `role_changed` event.
6. `AgentSocket`/`AgentChannel` role handling and Presence meta.
7. `Control` observer guard.
8. Role chip and disabled controls on `/admin/agents/:id`, `HomeLive`, agents
   index; `/v1/serving` role field.
9. `AIRO_DEV_BIND` in `config/dev.exs`; a paragraph in `DEPLOY.md` (or a new
   `docs/DEV.md`) with the operator prerequisites above.

## Tests (airo)

- `connect/3` accepts `role=observer`, defaults absent to controller, rejects
  `role=admin`.
- `register` with `agent.role: "observer"` persists `:observer`; a later
  register with `"controller"` writes `role_changed`.
- `Control.load/4` and `unload/3` on an observer agent return
  `{:error, :observer_role}` **and make no HTTP request** (assert via the S23
  `stub_control/1` seam that the plug is never called). `inventory/1` on the
  same agent does call through.
- `agent_live_online_test.exs` (S23) gains observer cases: chip rendered, Load
  and Unload disabled, Resync enabled. The existing online cases pin the
  controller branch unchanged.
- `/v1/serving` shows `"role": "observer"`.
- `dev.exs` bind is not unit-tested; it is checked in acceptance.

## Non-goals

- Agent-side enforcement of the role (needs per-airo tokens). The design note
  says why and what it would take.
- Runtime role changes, leases, or any "borrow this host" flow.
- Reducing the per-heartbeat inventory fetch. S25 measures; a follow-up fixes.
- Cross-airo awareness. Prod does not learn that dev is observing, except that
  the operator can see it in the agent's env file and log.
- Erlang clustering, shared databases, or any prod → dev data path other than
  the agent's own push.

## Risks

- **Two airos, one register stream each, doubled `GET /inventory` on the
  agent.** Bounded: `pvegpu` pilot first, S25's span shows the cost before the
  rest of the fleet follows. If it matters, cache inventory by revision on the
  airo side before widening.
- **The laptop is away most of the day.** Observer reconnect caps at 60 s;
  slipstream backoff already handles a dead endpoint without crashing the
  agent (the `handle_disconnect` fix in `notifier/channel.ex` is the reason
  serving survives airo outages today). Worth watching the agent journal on
  `pvegpu` for a day after the pilot.
- **Dev bound to the LAN with no socket token.** Same posture as prod today,
  which also runs with the token unset. Not made worse; not made better. If a
  token is ever set fleet-wide, dev needs the same one.
- **`host_id` collision in dev.** Dev's `agents` table may already hold rows
  from seeds or earlier local runs under the same `host_id` values. `Ingest`
  upserts by `host_id`, so the live push simply takes over the row; check
  `control_url` after the first register rather than assuming.
- **Presence meta contains `role` but Presence is per airo.** The tooltip's
  "controller is …" can only be filled if the agent reports its controller's
  host in `register`. v1 reports the role only; the tooltip falls back to
  "unknown". Adding `controller_host` to the payload is a one-line follow-up
  if it turns out to matter.

## Pilot result — pvegpu, 2026-09-04

Release `airo_agent-20260903-181552-ff8b4fa` deployed by jody with
`AIRO_OBSERVER_SOCKET_URLS=ws://jobybook.local.joby.gg:4004/agent` alongside the
prod controller URL. Verified:

- **Journal:** two connect lines one second apart — `llm.local.joby.gg:443 as
  controller` at 01:16:03 UTC, `jobybook.local.joby.gg:4004 as observer` at
  01:16:04 UTC. No `POST /load` or `/unload` since.
- **Dev airo:** `agents.role = :observer`, online, not stale, GPU telemetry live
  (16376 MB total, 2 MB used), slot `pvegpu:8081` empty, one `connected` host
  event carrying `role: observer`. `/v1/serving` reports `role: "observer"`.
- **Guard:** `Control.load/4` and `Control.unload/3` from dev return
  `{:error, :observer_role}`; `Control.inventory/1` still reads.
- **Prod:** `last_seen_at` continuous (2 s old when read, 28 min after the
  restart); zero `health_events` for `pvegpu:8081` in the window — nothing was
  resident, so nothing had a transition to record. Prod's `host_events` could
  not be checked: **S25 is not yet deployed to prod**, so the "only the
  restart's pair" assertion below waits for that deploy.

The `Load`/`Configure`/`Unload` disabled state and the observer chip were
confirmed on `/admin/agents` by jody. Remaining hosts follow in the order below
now that S25 is on prod (deployed 2026-09-04 02:04 UTC).

**Data path (2026-09-04 ~02:55 UTC):** jody loaded `QuantTrio/Qwen3.5-9B-AWQ:awq`
into `pvegpu:8081` and created a dev deployment for it. The observer airo
reconciled it from the push alone — `SlotState` `up`, ctx 29696, provenance
model `pvegpu_QuantTrio/Qwen3.5-9B-AWQ:awq_8081`, deployment 21 health `:up` —
and a chat completion through dev's gateway (`/v1/chat/completions`, concrete
model id, no alias) returned the expected text via `x-gateway-provider:
pvegpu:8081`, deployment 21, no fallback, 2203 ms. An observer routes
inference straight to the slot's `base_url`; the agent was never on the path.

## Rollout — 2026-09-04

| Host | Release | Prod pair (UTC) | Dev | Note |
|---|---|---|---|---|
| pvegpu | `ff8b4fa` (pilot) | 01:16 restart | observer, online | pilot; data path verified |
| forge | `ad55707` | 08:53:01 → 08:53:04 | observer, online | busiest host; 3 s gap |
| macmini | `ad55707` | 08:55:46 → 08:55:49 | observer, online | manual release, env carries both URLs |
| jobycorp | `ad55707` | 08:57:37 → 08:57:38 | observer, online | 1 s gap |
| sparky / sparky2 | — | — | — | in progress, done standalone by jody |

Every prod pair carries `role: controller`; every dev row carries `observer`.
Journals on forge and jobycorp show the two connects within 40 ms of each
other, observer first.

## Acceptance

- `pvegpu` deployed with both URLs. Its journal shows two `agent channel:
  connected` lines, one per endpoint, each naming its role.
- **Dev:** `HomeLive` shows `pvegpu` online with live GPU rings within one
  heartbeat; `/admin/agents/:id` shows the observer chip, the resident model
  from the push, inventory from `control_url`, Load/Unload disabled; a chat
  completion through dev's gateway against the alias bound to `pvegpu:8081`
  succeeds, proving the data path.
- **Dev, in `iex`:** `Airo.Agents.Control.load(agent, model, 8081)` returns
  `{:error, :observer_role}` and the agent's access log shows no `POST /load`.
- **Prod:** `GET /v1/serving/hosts?since=<deploy time>` for `pvegpu` shows
  exactly the `disconnected`/`connected` pair from the agent restart and
  nothing else — no `stale`, no extra drops. `airo_host_online` never read 0
  outside that window. Prod's `/admin/agents/:id` for `pvegpu` still shows
  controller and enabled controls.
- Remaining hosts follow in cost order — a redeploy drains every engine on the
  host (`bin/deploy.sh` header), so: `sparky2` second (no slots of its own,
  proves the slot-less case for free), then `macmini` (idle, manual release,
  the only macOS agent), then `jobycorp` (its alias partner `forge` absorbs
  the reload), then `forge` (busiest), then `sparky` last, in a planned window,
  because its 685B TP=2 reload is the longest in the fleet.
- Both suites green; `mix joby_kit.lint` clean; `mix precommit` green in both
  repos.

## Deferred (pre-declared)

- Per-airo tokens on the agent, and the agent refusing `POST /load` from an
  observer — turns the role from a courtesy into a guarantee.
- `controller_host` in the register payload for the observer tooltip.
- Inventory caching / moving `inventory_index/1` off the register path, sized
  by S25's measurements.
- Runtime role flip ("lease `pvegpu` to dev for an hour") once agent-side
  enforcement exists.
