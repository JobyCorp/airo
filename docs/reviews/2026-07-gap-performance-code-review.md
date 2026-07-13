# Airo — Gap, Performance & Code Review

Fresh read of the gateway (S0–S21), managed agent control plane, and sibling
`airo_client`. Thesis: singular OpenAI-shaped routing endpoint for distributed
model serving — with operator-driven host agents.

**Sources:** `docs/sprints/STATUS.md` + `docs/design/`, `lib/airo` (~59 modules),
`airo_client` v0.1.0 git package · Jul 2026

| Metric | Value |
|--------|-------|
| Sprints closed | S0–S21 |
| ExUnit tests (at S21) | ~354+ |
| `/v1` capabilities | 9 |
| Open sprints | 0 |

## Verdict

Airo is past the “build the gateway” phase. The front door, routing, adapters,
observability, model shelf, and operator agent plane are shipped and in
production use by incogito/orchester. Remaining work is operational hardening,
distribution polish, and deliberate product choices — not missing core
architecture.

## Where you are

Three layers, all real: gateway service, Elixir client, host agent control.
Automatic placement was considered and rejected — packing is operator + VRAM
validation, not dispatch-time magic.

| Domain | Status | Notes |
|--------|--------|-------|
| Config plane | Shipped | Providers, deployments, aliases, keys, secrets, models, agents, routing settings |
| Chat / OpenAI front door | Shipped | resolve → authorize → route → dispatch; failover; transparency headers |
| Streaming SSE | Shipped | Pre-byte failover; `gateway.metadata` trailer; mid-stream no failover (by design) |
| Capability breadth | Shipped | chat, embed, rerank, classify, speech, transcribe, voices, realtime WS |
| Health-aware routing | Shipped | ETS health + preference; priority/weighted/rr; class/tools/vision filters |
| Classification routing | Shipped / opt-in | Shadow/enforce modes; Infinity default; Ortex opt-in; cloud tier deferred |
| Observability | Shipped | Usage, traces, log_events, admin drilldown, health history |
| Model Shelf | Shipped | Durable models + local sync; polish items deferred (scheduled sync, pull UI) |
| Agent control plane | Shipped | Operator load/unload/configure; SlotState; provenance; VRAM hard-block |
| Auto placement / eviction | Out of scope | Explicitly rejected in design — operator-driven only |
| airo_client (Hex) | Git-only | Full `/v1` coverage; Hex publish deferred; consumer commit drift |
| Consumer cutover | Done | incogito + orchester use Airo as sole gateway path |

### System map

| Layer | Role |
|-------|------|
| **Consumers** (incogito · orchester) | Thin adapters over `airo_client` (git). App orchestration stays local — Airo never learns conversations. |
| **Gateway** (this repo) | OpenAI-shaped `/v1` + admin. Config plane, routing, adapters, shelf, agent ingest/control, usage/logs. Standalone Phoenix release. |
| **Host agents** | Push state · pull control. WS register/slot → SlotState + provenance. HTTP load/unload from `/admin/agents`. VRAM validate blocks bad ctx configs. |

## Gap analysis

Ordered by risk to the thesis (“one reliable routing endpoint”), not by novelty.
Auto-placement is a non-gap — design says no.

| Pri | Gap | Why it matters | Effort |
|-----|-----|----------------|--------|
| P0 | Admin UI has no app-level auth | Browser routes under `/admin` rely on network trust; keys/secrets/agents are exposed if the host is reachable | M |
| P1 | Classifier enforce cutover is operational, not product-complete | Shadow works; enforce adds sync latency; cloud tier + `x-route-class` header still missing | S–M |
| P1 | airo_client distribution & consumer drift | Git `branch: main` pins; incogito/orchester lag main; README still shows fake Hex install | S |
| P1 | Agent load path still operator-manual | By design — but means cold models miss requests until someone loads; no drain-on-restart | L (if revisited) |
| P2 | Model Shelf polish | Scheduled sync, pull UI, subjective scoring, serving-facts UI deferred from S12/S19 | M |
| P2 | Doc/code drift on slot profiles | S20 closed as ctx-only; UI now sends thinking + sampling penalties — sprint docs stale | S |
| P2 | Thin realtime + live-agent E2E tests | Realtime has ~6 tests; agent load E2E needs a reachable host; no load harness | M |
| P3 | Transparency headers not fully client-exposed | Streaming gets `gateway.metadata`; non-stream drops `x-gateway-*`; no client trace forwarding | S |

> **Explicit non-goal.** Automatic placement / eviction on dispatch is out of
> scope across agent design docs. Do not reopen unless the operator model fails
> in practice — it would couple routing latency to load/unload and change the
> failure domain.

## Performance review

**Strong — hot-path shape.** Request path is resolve → ETS health → Finch. No
GenServer hop for routing counters or slot reads. Classifier shadow stays off
the critical path.

**Watch — enforce mode cost.** Ortex ~parity with Infinity LAN (p50 ~44ms). Fine
for selective aliases; wrong as a global default without measuring consumer SLOs.

**Watch — async fan-out.** Usage + Logs via `Task.Supervisor` is fail-open and
correct. Under traffic spikes, add metrics on task backlog before it becomes
silent memory pressure.

| Path | Cost | Risk | Notes |
|------|------|------|-------|
| Chat resolve + route | DB preload + ETS health/rr | Low | Hot path avoids GenServer; ETS read concurrency is correct |
| Upstream Finch pools | Default ~50/host | Med | Tune under concurrent SSE; chat timeout raised to 300s (good) |
| Classifier enforce | ~44–80ms Ortex p50/p95 | Med | Sync on request path; shadow is detached — keep enforce selective |
| Usage / Logs async | Task.Supervisor fire-and-forget | Med | Fail-open is right; no backpressure under spike — watch mailbox growth |
| Agent slot ingest | Inventory HTTP + provenance + N health writes | Med | Per push, not per request — fine at operator cadence; noisy if agents flap |
| Streaming failover | Pre-byte only | Low | Correct tradeoff; mid-stream retry would corrupt clients |
| LocalClassifier Holder | `:persistent_term` once | Low | Boot warmup + contract assert; zero GPU; good OTP shape |

## Code review

| Signal | Value |
|--------|-------|
| `gateway.ex` | ~502 LOC |
| `agent_live.ex` | ~1072 LOC |
| `lib/` TODOs | 0 |
| `airo_client` | ~760 LOC |

| Finding | Severity | Detail |
|---------|----------|--------|
| Gateway as intentional hub | Info | ~500 LOC orchestrator coupling Config/Routing/Classifier/Health/Logs — expected; keep adapters thin |
| AgentLive size (~1070 LOC) | Med | UI + async control + VRAM validation in one LiveView — extract domain helpers before next agent sprint |
| Clean of TODO/FIXME in `lib/` | Good | No stub markers; deferred work lives in design docs — healthy discipline |
| ETS-owned runtime state | Good | Health, routing counters, slots owned by thin GenServers; callers hit ETS directly |
| Fail-open classifier + async observability | Good | Serving never blocked by logging or classifier errors — correct gateway posture |
| AgentSocket open when token unset | Med | Dev convenience; ensure prod always sets `:agent_token` (moduledoc notes this) |
| `x-route-class` documented, unimplemented | Low | DESIGN-chat-routing forward caveat — callers must use body `route.class` today |
| airo_client thin & complete | Good | ~760 LOC; mirrors all `/v1` endpoints; retries disabled (Airo owns failover) — right split |

## Recommended next moves

Updated 2026-07-09 after operator feedback: **admin auth** and **cloud routing**
are deferred. Classifier has been calibrated on live traffic — **enforce
cutover is go**. Remaining gaps are mostly low-hanging fruit.

### Do now

1. **Enforce cutover** (ops, no deploy) — On each routed alias (`router: classify`),
   set Mode → **Enforce** in `/admin/aliases/:id`. Fail-open still applies on
   classifier error/timeout. Watch `/admin/logs` for `route_prediction` + served
   class, and usage for edge vs deep mix. Flip back to Shadow if wrong.
2. **airo_client hygiene** — Real README; tag releases; pin incogito/orchester to
   tags (kill `branch: main` drift).
3. **Doc drift** — S20 said ctx-only profile; UI now has thinking + sampling
   penalties — update sprint/design notes.
4. **Client transparency (optional)** — Expose `x-gateway-*` on non-stream
   responses; optional outbound trace id.

### Later / polish

- Model Shelf: scheduled sync, pull UI, serving-facts
- Realtime + live-agent E2E depth
- Extract helpers from `AgentLive` before the next agent feature
- `x-route-class` header (callers use body `route.class` today)

### Explicitly deferred

- **Admin auth** — network trust for now
- **Cloud routing tier** — edge/deep covers current hosts
- **Auto placement on dispatch** — out of scope; separate control loop only if
  the operator model fails in practice
