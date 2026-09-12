# Sprint 28 — Serving activity: loaded, max concurrency, available concurrency

> **Status: planned 2026-09-12, not started.** Scope set by jody on 2026-09-12
> after a review of four proposed airo additions for agent orchestration:
> memory pressure is **not** a measure of availability for agents; the signals
> the harness will act on are **Model Loaded**, **Max Concurrency** and
> **Available Concurrency**. helm holds a management-scoped key as of the same
> day, so S27 deliverable 4 is closed and every `/v1/serving*` route is
> readable from the harness.

> **Goal (one sentence):** give an orchestrating harness three per-deployment
> facts it can act on — is the model loaded, how many requests can it take, how
> many can it take *right now* — computed by Airo from state it already holds,
> on an endpoint built to be polled.

> **Why now.** jody is adding agent orchestration to helm to saturate models
> that sit idle all day. Today a consumer has to infer "busy" from GPU
> utilisation and power, and that proxy is wrong on exactly the hosts that
> matter: a resident model sits at 0% util with its memory pinned. Nothing in
> Airo counts in-flight requests, even though every one of them passes through
> `Airo.Gateway`.

---

## What's there now (verified 2026-09-12, 17:15 UTC, from the dev observer)

**The fleet, at idle.** Six hosts online, every slot `up`, GPU util `0.0` on
every host that reports it, power at idle. Both vLLM engines report zero
running, zero waiting, 0% KV cache in use.

| Host | Memory source | Used / total MB | Resident | `parallel` |
|---|---|---|---|---|
| forge | nvml | 31,752 / 32,607 | Qwen3.6-35B-A3B NVFP4 (vLLM) | 4 |
| jobycorp | none reported | — | Qwen3.6-35B-A3B NVFP4 (vLLM) | 4 |
| pvegpu | nvml | 12,692 / 16,376 | gemma-4-12B w4a16 (vLLM) | 4 |
| sparky | unified | 119,606 / 124,546 | DeepSeek-V4-Flash, TP rank 0 (vLLM) | 4 |
| sparky2 | unified | 119,274 / 124,546 | DeepSeek-V4-Flash, TP rank 1 | nil |
| macmini | unified | 10,105 / 16,384 | Qwen3.5-9B Q4_K_M (llama.cpp) | 1 |

The 96–97% memory readings on forge and sparky are vLLM's KV-cache
preallocation (`gpu_memory_utilization`), on discrete and unified hosts alike.
They say "vLLM reserved its budget", not "the model is under pressure" — which
is why memory is out of scope here.

**The `ETag` on `GET /v1/serving` never matches while a host is online.** Two
base snapshots taken 6 s apart hashed differently. `etag_basis/1` drops only
clock-derived fields (`generated_at`, `age_ms`, `checked_at`, `updated_at`);
`last_seen_at` moves on every heartbeat, and `gpu.power_draw_w` /
`gpu.vram_used_mb` wobble on every 5 s poll (`9.76` → `9.71` W on forge,
`10104.97` → `10104.69` MB on macmini). The `304` path is dead code today, so
the S27 note about `?speculative=1` "defeating" it was protecting nothing.

**Inputs that already exist**

- `Airo.Agents.SlotState` — per slot: `resident_model`, `model_id`, `status`
  (`empty|loading|up|down`), `parallel`, `tp_rank`. `parallel` is
  `--max-num-seqs` on vLLM and `--parallel` on llama.cpp (the agent reads
  `total_slots` from llama-server's `/props`). That **is** max concurrency.
- `Airo.Agents.Liveness` — `online?/1`, `stale?/1`. `Airo.Health` — status
  per deployment, decayed to `:unknown` when stale.
- `Airo.Adapters.VLLM.metrics/1` — already parses `num_requests_running`,
  `num_requests_waiting` and `kv_cache_usage_perc` per `model_name`;
  `Airo.Serving` scrapes it for S27 and discards those three.
- `Airo.Gateway.run_attempts/3` and `stream_attempts/5` — the one place every
  HTTP inference request passes, in the connection process.
  `AiroWeb.RealtimeProxy` holds `state.target.deployment` for the life of a
  WebSocket session.
- llama.cpp slots have **no engine-side request counter**: the agent launches
  llama-server without `--metrics` or `--slots`. For those, the gateway count
  is the only busy signal until an `airo_agent` flag change lands.

## Design

1. **`Airo.Gateway.InFlight`** — a `Registry` (`keys: :duplicate`, key =
   deployment id, value = `%{capability, client_key_id, started_at}`), started
   under the application supervisor. `track/2` registers the *calling*
   process; `release/1` unregisters it; `count/1` and `snapshot/0` read.
   Registering the request process — not incrementing an ETS cell — is the
   whole point: a client that disconnects mid-stream, or a crash anywhere in
   the request, releases the entry automatically. An ETS counter would leak,
   and with a 300 s chat timeout a leaked entry hides a sequence for minutes.
2. **Gateway wraps each attempt.** `track` before the adapter call, `release`
   after — on success, on error, and **before** failing over to the next
   attempt, so a fallback never double-counts. Streaming: same, in the
   connection process; a `partial_error` releases explicitly even though the
   process will exit anyway. Realtime: `track` in `RealtimeProxy.init/1` once
   the target is resolved; process exit covers release.
3. **Three facts per deployment.**
   - `loaded` — true when the deployment's slot reports `up` **and**
     `SlotState.model_id` equals the deployment's `model_id` — the same S19
     identity rule `Ingest` uses to mark health. `slot_status` says why not:
     `empty | loading | down | stale | not_resident`. External providers (no
     slot) report `loaded` from prober health with `slot_status: "external"`.
     A TP rank > 0 (`serves_api: false`) never reports `loaded`.
   - `max_concurrency` — `SlotState.parallel`; `nil` when unknown (external
     providers, non-head ranks).
   - `in_flight` — the gateway count. `available_concurrency` —
     `max(max_concurrency - in_flight, 0)`, `nil` when `max_concurrency` is.
4. **Engine counters, opt-in.** `?engine=1` scrapes each vLLM slot's
   `/metrics` (the S27 machinery, same 4 s budget, same "absent, never zero"
   degradation) and attaches `engine: %{running, waiting, kv_cache_pct,
   scraped_at}`. When present, the availability arithmetic uses
   `max(in_flight, engine.running)` and the block names which won (`source:
   "gateway" | "engine"`). Why: the gateway count is authoritative only for
   traffic through Airo. helm already scrapes engines directly (S27) and every
   vLLM port is open on the LAN, so direct callers are invisible to Airo and
   visible to the engine. Queue depth (`waiting`) is reported, **not** folded
   into availability — see open question 1.
5. **`GET /v1/serving/activity`** — management scope. One query (deployments
   with provider and agent), ETS reads, Registry counts; no inventory call, no
   usage-table lateral. Payload: `generated_at` and `deployments: [%{id,
   model_name, upstream_model_id, provider, host_id, capabilities, class,
   eligible, routable, loaded, slot_status, max_concurrency, in_flight,
   available_concurrency, engine}]`. **No `ETag`** — it changes on every
   request start and end by construction — and `cache-control: no-store`.
   Target: single-digit milliseconds without `engine=1`.
6. **Repair the topology `ETag`.** Drop `last_seen_at` and the whole `gpu`
   map from `etag_basis/1`; `online` and `stale` stay, because they are the
   liveness facts. `/metrics` keeps carrying the raw telemetry. `loaded` and
   `max_concurrency` are stable enough to ride the base snapshot too, so add
   them there; `in_flight` and `available_concurrency` do **not** go on it.
7. **`/metrics` gauges** — `airo_deployment_loaded`,
   `airo_deployment_max_concurrency`, `airo_deployment_in_flight`,
   `airo_deployment_available_concurrency`, labelled `deployment_id`, `model`,
   `host_id`; the first two always, the last two always (they are free), the
   engine family only from the existing S27 scrape path.
8. **Admin UI, small.** The slot row on `/admin/agents/:id` and the ring card
   on `HomeLive` show "N / M in flight" through the existing wrappers. Nothing
   else changes on screen.

## Deliverables

1. `Airo.Gateway.InFlight` (Registry + API), supervised; tracked in
   `Gateway.run_attempts/3`, `stream_attempts/5` and `RealtimeProxy`.
2. `Airo.Serving.activity/1` and `GET /v1/serving/activity` with `engine=1`,
   OpenAPI documented; `loaded` + `max_concurrency` added to the base snapshot.
3. `ServingController.etag_basis/1` drops `last_seen_at` and `gpu`.
4. The four gauges on `/metrics`.
5. "N / M in flight" on the agent page and the home ring cards.
6. README API section and `docs/design/DESIGN.md` §10: one paragraph each on
   what `available_concurrency` is and is not (memory is not in it; direct
   callers are only counted with `engine=1`).

## Tests

- **`InFlight`**: count is 1 while a tracked process holds the entry, 0 after
  `release/1`, and 0 after the tracked process is killed without releasing;
  two processes on one deployment count 2; `snapshot/0` omits deployments
  with no entries.
- **Gateway**: with the S2 stubbed `Req` plug, assert **from inside the plug**
  that `InFlight.count/1` is 1 during the upstream call and 0 after the
  response for `run/1` and `run_stream/4`; a retryable 5xx on the first
  attempt leaves the first deployment at 0 before the second is called; a
  `partial_error` mid-stream releases.
- **Realtime**: a relayed session counts 1 for its deployment until the socket
  closes (the S8 echo-upstream test).
- **`activity/1`**: `loaded` true for an `up` slot whose `model_id` matches;
  false with `slot_status` for `empty`, `loading`, `down`, a stale host, and a
  resident model belonging to a *different* deployment on the same slot;
  `max_concurrency` from `parallel`, `nil` for a rank-1 slot and an external
  provider; `available_concurrency` clamps to 0 and is `nil` when max is;
  `engine` is `nil` without `engine=1` (proved by leaving the engine unstubbed
  so any scrape would raise); with `engine=1`, `engine.running` larger than
  the gateway count wins and `source` says so; an unreachable engine degrades
  to `engine: nil` with the gateway arithmetic intact.
- **Controller**: 403 for an inference key; no `etag` header; `no-store`.
- **`ETag`**: two snapshots differing only in `last_seen_at` and `gpu` hash
  equal; a slot status change hashes differently. (Regression for the dead
  `304` path found on 2026-09-12.)
- **`/metrics`**: the four gauge names, label sets and values.

## Non-goals

- **Memory headroom or pressure as an availability input.** jody's decision,
  2026-09-12. The S18 "Spark unified-memory budget" item stays deferred; the
  96% readings are vLLM's preallocation, not a Spark accounting error.
- **Least-loaded routing.** Natural once the counter exists (`Airo.Routing`
  strategies are priority, weighted and round-robin today); a follow-up sprint.
- **Engine-side counters for llama.cpp.** Needs `--metrics` / `--slots` on the
  agent's launch line — an `airo_agent` change, not this sprint.
- **A capability-addressed eligibility read.** The activity payload carries
  `capabilities`, `class`, `eligible` and `routable`; the harness filters.
  A server-side selector would be a second routing brain beside S13/S16.
- **Raising `max-num-seqs`.** The vLLM fleet is capped at 4 per slot, so
  `available_concurrency` will read 0 almost immediately under orchestration.
  That is the truth, and raising it is a launch-profile decision made in the
  S20 config modal, not an API gap.
- Per-client-key quotas or admission control. The Registry value already
  carries `client_key_id`, so a per-key split is cheap later.

## Risks

- **Direct callers are invisible to the gateway count.** Mitigated by
  `engine=1` and by naming the `source` in the payload. Not fully closable:
  llama.cpp exposes nothing until the agent flag change.
- **vLLM KV budget is `:uncalibratable` (S22)**, so nothing guards a
  `max-num-seqs` increase against the KV pool. Watch
  `num_preemptions_total`, which the scrape already carries.
- **The activity endpoint is un-cacheable by design.** A tight poll from
  several consumers is one DB query plus ETS reads per call; fine at this
  fleet size, and the `engine=1` scrape stays opt-in for exactly this reason.
- **Failover release ordering.** Releasing *after* the next attempt starts
  would double-count for the duration of one upstream call; the test pins the
  order.

## Acceptance

- From helm, with its management key, `GET /v1/serving/activity` lists the
  five API-serving slots `loaded: true`, `max_concurrency` `4 / 4 / 4 / 4 / 1`,
  and `available_concurrency` equal to max at idle; `sparky2:8081` reports no
  `loaded` and `nil` max.
- Fire N concurrent chat requests at an alias through Airo: `in_flight` rises
  to N (capped at max), `available_concurrency` falls, both return to idle
  values after the last response.
- Kill a client mid-stream: the count is back to 0 within one second, with
  no `release/1` having run.
- With `engine=1`, a request sent straight to `sparky:8081` (bypassing Airo)
  shows `engine.running: 1`, `in_flight: 0`, `source: "engine"`.
- `GET /v1/serving` with `If-None-Match` returns `304` on the second poll
  while nothing but heartbeats and telemetry has changed.
- Both suites green; `mix precommit` and `mix joby_kit.lint` clean.

## Open questions for jody

1. **Queue depth.** With `engine=1`, should `waiting > 0` drive
   `available_concurrency` to 0 even when `running < max`? Recommended: no —
   report `waiting` beside it and let the harness decide, because a non-zero
   queue with free sequences is a transient scheduler state, not capacity.
2. **Per-key split in v1?** `in_flight_by_key` is a one-line addition once the
   Registry value holds `client_key_id`. Recommended: leave it out until a
   second consumer exists.
