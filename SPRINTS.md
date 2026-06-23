# Airo — Sprint Process

Lightweight, scope-boxed process for standing up Airo. See [DESIGN.md](./DESIGN.md)
for the architecture this builds toward.

## How we work

- **A sprint is a vertical slice**, not a week. It's done when it compiles, is
  tested, and moves the system one mergeable step forward — however long that takes.
- **One sprint = one branch** named `sprint/NN-slug` (e.g. `sprint/00-foundations`),
  merged to `main` when the Definition of Done is met. `main` always compiles.
- **Track in-sprint work** with the session task list; this file is the durable
  cross-session record — tick the checkbox when a sprint merges.
- **Commits** end with the co-author trailer; keep the subject imperative and scoped.

## Definition of Done (every sprint)

- [ ] `mix precommit` green (`compile --warnings-as-errors`, `deps.unlock --unused`,
      `format`, `test`)
- [ ] New behavior has tests (adapters tested against a stubbed Req plug, not live)
- [ ] `mix joby_kit.lint` green *if the sprint touched UI*
- [ ] `DESIGN.md` updated if any decision changed; `SPRINTS.md` checkbox ticked
- [ ] Branch merged to `main` and pushed

## Definition of Ready (before starting a sprint)

- Goal is one sentence; deliverables are listed; it depends only on merged sprints.

---

## Backlog (ordered — each depends on the previous)

### [x] S0 — Foundations & config plane
No provider calls yet; just the schema both apps converge onto.
- Cloak vault + `Airo.Encrypted.Binary` Ecto type
- Migrations + schemas + changesets: `Provider`, `Deployment`, `Alias`,
  `ClientKey`, `Secret`, `UsageRecord` (DESIGN §8)
- `Airo.Config` context(s); dev seeds for one local provider
- **DoD extra:** migrations run clean; changeset tests cover required fields + enums

### [x] S1 — Transport & adapter behaviour
- `Airo.Adapter` behaviour (`chat/stream/embed/rerank/speech/transcribe`)
- Own Req/Finch wrapper; one Finch named pool per `Provider` (DESIGN §13)
- `Airo.Registry` (adapter type → module)
- First OpenAI-compatible adapter: **chat, non-streaming**
- **DoD extra:** adapter unit-tested against a stubbed Req plug

### [x] S2 — Chat front door (first end-to-end slice)
- `POST /v1/chat/completions` (non-streaming): alias → normalize → adapter → response
- Client-key auth plug (hashed lookup, `allowed_aliases` scope)
- Param normalization v1: layered defaults (provider<deployment<alias<request),
  `provider_params` passthrough, unknown-key passthrough (DESIGN §7)
- **DoD extra:** real request against a local vLLM/Ollama succeeds

### [x] S3 — Streaming & transparency
- SSE streaming for chat, normalized to OpenAI deltas (tools, `reasoning_content`)
- `x-gateway-*` response headers + SSE trailing event (DESIGN §5.1)
- **DoD extra:** streamed tokens + trailer verified

### [x] S4 — Routing core
- Multi-candidate selection: `weighted | priority | round-robin`
- Health prober → ETS/`:persistent_term` (~90s staleness signal, not hard gate)
- Failover/retries along the fallback chain
- Strict pin via `route.binding` → serve or `selected_binding_unavailable`
- **DoD extra:** routing + failover unit-tested with a downed stub

### [x] S5 — Capability breadth
- `/v1/embeddings`; unified `/v1/models` (aggregate healthy providers)
- Anthropic adapter (Messages API + claude-code OAuth refresh, normalized out)
- Infinity `/v1/rerank`; Speaches `/v1/audio/{speech,transcriptions}`
- **DoD extra:** each capability has an adapter + test

### [x] S6 — Observability & config UI
- Async `UsageRecord` writes + cost from `Deployment` pricing
- LiveView admin (JobyKit) for Providers/Deployments/Aliases/Keys + usage view
- OpenAPI spec via `open_api_spex`; Oban prune worker for `UsageRecord`
- **DoD extra:** admin CRUD works; spec served at `/openapi`; usage recorded

### [x] S7 — Consumer migration
- incogito: repoint `base_url` → Airo; send concrete model ids or single-candidate aliases
- orchester: delete resolver, repoint dispatch, translate strict pins → `route.binding`;
  keep Sink / agent loop / `:queued` Oban app-side
- **DoD extra:** both apps green against Airo
- _Complete: incogito and orchester now use Airo as the sole path to AI models._

### [x] S8 — Realtime proxy
See [DESIGN-realtime-and-client.md](./DESIGN-realtime-and-client.md) §4.
- `/v1/realtime` WebSocket (Bandit `WebSock` in, `Mint.WebSocket` out), Bearer auth
- Connect-time resolution + health routing; internal/external provider brokering
- Session-grained `UsageRecord`; `x-gateway-*` on the upgrade; transparent pass-through
- **DoD extra:** an app server relays browser STT through Airo to Speaches end-to-end

### [ ] S9 — `airo_client` hex package
See [DESIGN-realtime-and-client.md](./DESIGN-realtime-and-client.md) §6.
- HTTP capabilities (chat/embed/rerank/speech/transcribe/models) + streaming-as-messages
- `airo_client_realtime` relay-to-Airo; replaces `openai_ex` in both apps
- **DoD extra:** incogito/orchester drop per-provider transport code; both green on the package

### [x] S10 — API docs (`/docs`)
A Swagger UI reference at `/docs` (like Infinity's), backed by the existing
`open_api_spex` document at `/openapi`.
- `get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/openapi"`; nav link; `/docs` open (LAN), Bearer authorize for try-it-out
- Enrich `AiroWeb.ApiSpec`: add the missing `/v1/classify` path; add request/response **schemas + examples** for every endpoint, the `route` object (`class`/`tools`/`vision`), and `capabilities` on `/v1/models`
- Decide CSP/offline: vendor Swagger UI assets into `priv/static` vs CDN (LAN browsers need internet for the CDN)
- **DoD extra:** `/docs` renders every `/v1` path with request/response detail; "Authorize" + try-it-out works against a real key

### [x] S11 — Gateway observability
Post-cutover production observability for Airo as the single AI model path for
incogito and orchester.
- Trace identity: every HTTP request, SSE stream, and realtime session carries a
  gateway trace id in response metadata, logs, and persisted usage/audit records
- Structured gateway logs for request start/finish, resolution, attempt failures,
  fallback, stream partial errors, and realtime close events
- Failed-request accounting: persist traceable rows for auth, routing,
  unsupported capability, upstream HTTP errors, transport errors, stream partial
  errors, and realtime connection failures
- Usage admin upgrade: filters by client/capability/model/outcome/time range,
  trace-id copy/link affordance, and summary cards for count, error rate,
  p50/p95 latency, fallback count, and cost
- Provider/model health history sufficient to explain incidents and feed the
  future Model Shelf
- **DoD extra:** a failed request and a successful streamed request can both be
  correlated across response headers/SSE metadata, logs, and `UsageRecord`;
  realtime sessions carry one trace id from connect through close
- _Complete: implemented on `sprint/11-gateway-observability`; `mix
  precommit` and `mix joby_kit.lint` green._

### [ ] S12 — Model Shelf
A model-management layer over the gateway so Airo can answer operational and
evaluation questions about model artifacts, versions, deployments, and routing
posture across many local machines.
- Add a durable model/version identity separate from `Deployment`: the model is
  the artifact/lineage/version being evaluated; deployments are runnable copies
  of that model on providers/machines
- Link existing and new deployments to model records while preserving current
  concrete `model` request behavior and alias routing
- Add a Model Shelf admin surface: list models with capability, class, enabled
  deployment count, health posture, usage volume, latency p50/p95, error rate,
  fallback rate, and cost
- Add model detail pages that show deployment copies by provider/machine, version
  metadata, routing participation, recent health transitions, recent traces, and
  per-deployment performance breakdowns
- Capture model metadata needed for evaluation: display name, family, upstream
  model id, version/build/revision, quantization/size when known, notes, and
  lifecycle status (`evaluating`, `preferred`, `deprecated`, `disabled`)
- Keep routing source-of-truth explicit: aliases still route traffic, but model
  pages expose which aliases/candidates currently lean on each model and where
  duplicate deployments provide failover
- Local provider management first: add a provider-specific management contract
  for local runtimes, implement Ollama native catalog/inspect/pull/runtime info,
  then follow with LM Studio and vLLM runtime metadata; remote/cloud provider
  management stays backlog
- Ollama proof-out: persist provider-native metadata on each deployment copy,
  sync it from the model detail page, update the shared model's family/size/
  quantization from native inspect output, and surface runtime/version/family/
  parameter/quantization/context/running details beside performance rows
- Local-provider follow-up blueprint:
  1. LM Studio: catalog + runtime/download metadata implemented; load/unload UI
     remains a later control surface
  2. vLLM: served-model metadata, context length, conservative family/size/
     quantization derivation, and selected Prometheus runtime metrics
     implemented; no pull/install workflow assumed
  3. Background sync: scheduled metadata refresh per enabled local deployment,
     with last sync status/error on the deployment row
  4. Infinity: embeddings/rerank/classify model metadata, queue stats, backend,
     and endpoint metrics implemented
  5. Speaches: speech/transcription model metadata, language/voice/sample-rate
     inventory, and loaded-model runtime state implemented
  6. Provider pages: local runtime inventory and currently loaded/running models,
     so machine-level capacity and duplicate failover copies are visible
  7. Evaluation layer: compare provider copy/version cohorts using existing
     `UsageRecord` latency/error/fallback/cost groups before adding subjective
     quality scoring
- **DoD extra:** given two deployments of the same model on different providers,
  the shelf shows them as one model with separate operational rows and aggregate
  performance; updating a model version creates visible before/after comparison
  data from `UsageRecord` without breaking existing gateway calls

### [x] S13 — Routed `chat` alias (classification-driven tiering)
See [DESIGN-chat-routing.md](./DESIGN-chat-routing.md). Depends on S4 (routing),
S5 (Infinity classify adapter), S11 (trace/logs) — all merged.
A `chat` alias that classifies the prompt and routes to a model *tier* by
computing `route.class`; reuses candidate/health/failover wholesale. Ships in
**shadow mode** (logs its decision without acting) to calibrate before enforcing.
- `aliases.router` (`:none|:classify`) + `aliases.router_config` map; non-breaking
  (existing aliases default `:none`) — migration + changeset (DESIGN §8)
- `Airo.Routing.Classifier`: prompt → `route.class` via the configured `:classify`
  alias (Infinity deberta zeroshot), ordered labels + thresholds, **fail-open** on
  error/timeout (`timeout_ms` budget)
- One hook in `Gateway.alias_target/3`: set `route.class` in `enforce`, log-only
  in `shadow`; skipped when the caller pinned `route.class`/`route.binding` (DESIGN §9)
- `chat` + `prompt-class` config; structured `gateway.route.classified` log (S11 trace)
- **DoD extra:** T0 spike pins the Infinity `/classify` zero-shot contract; enforce
  filters to the predicted class, shadow serves the priority head and logs; a
  `router: :none` alias is byte-for-byte unchanged (non-regression test)

### [x] S14 — Logging & traceability
See [DESIGN-logging-traceability.md](./DESIGN-logging-traceability.md). Builds on
S11 (trace ids/logs) and S13 (classifier predictions).
A persisted operational event log at `/admin/logs` + cross-surface traceability by
`trace_id`, so calibration and request debugging happen in-app — `/usage` stays
consumption-focused (tokens/cost/latency).
- `log_events` table (`kind`/`level`/`trace_id`/`summary`/`data` jsonb + alias/provider/
  deployment refs); `Airo.Logs` context (`record/1` async, `list/2`, `for_trace/1`),
  pruned by the existing Oban housekeeping
- Capture **off the hot path** (async writer reusing the Task.Supervisor, **not** a
  Logger handler): route predictions (`gateway.route.classified`) + health transitions
  (dual-write from `Health.record_event`); existing stdout Logger lines stay
- `/admin/logs` LiveView (stat strip + filters: kind/level/range/alias/predicted_class/
  trace) modeled on `/usage`; "Logs" nav entry; cross-links to/from `/usage`
- **Traceability:** a trace drilldown stitching the `/usage` row + all `log_events` for a
  `trace_id` into one timeline
- **DoD:** predictions + health visible/filterable in `/admin/logs`; a `trace_id`
  correlates a request across `/usage` and logs; capture adds no request latency and
  can't recurse; `/usage` byte-for-byte unchanged

### [x] S15 — Local ONNX classifier (Ortex, on-CPU validation slice)
See [DESIGN-local-classifier.md](./DESIGN-local-classifier.md).
Depends on S13 (classifier seam, `router`/`router_config`, `Classifier.score/2`).
Prove the routing classifier can run **natively on the BEAM, on CPU, end-to-end**
via Ortex with an **off-the-shelf** ONNX model — before any fine-tune or enforce
cutover. Goal: a `:classify` alias can compute `route.class` with **zero GPU /
Infinity call**, inside the existing latency budget. v1 swaps the **axis**, not
just the engine: route on a **graded 0–1 complexity score** (NVIDIA
`prompt-task-and-complexity-classifier`, DeBERTa-v3-base, single pass) thresholded
into a tier ladder — fixing the S13 topic-entailment path that treats code as a
binary signal. Stock model only; the fine-tuned router and switching the default
backend are a later sprint.
- **Dep chain (build host):** add `{:ortex, …}` + `{:tokenizers, …}` to `mix.exs`;
  install Rust + sort the native build (ORT binary fetch) **on the build host**
  (we build locally and ship a precompiled release tarball — the VM never runs
  `mix compile`); `mix deps.get` + `compile --warnings-as-errors` clean; `mix
  precommit` green; the NIF `.so` + ORT lib ride inside the tarball, VM needs no Rust
- **Model artifact + export gate:** NVIDIA complexity classifier — a **custom
  multi-head** model, *not* `optimum-cli`-exportable, and DeBERTa-v3 export is a
  documented silent-wrong hazard. Hand-export on the fleet, **gate on numerical
  equivalence (torch vs ONNX logits)**; fall back to `deberta-v3-base-zeroshot`
  (clean export, Infinity parity ref) if it fails. `mix airo.fetch_model` →
  `priv/models/<name>/` (**gitignored**, fetched **before `mix release`** so it
  ships), checksum + recorded graph-input/head-order contract
- **`Airo.Routing.LocalClassifier`:** load ORT session + tokenizer **once** at boot
  (`:persistent_term` / named process, low intra-op threads, warmup); single-text
  encode (no pair) → run → **`process_logits` ported to Nx** (softmax + weighted
  complexity scalar) → return `%{class => c}` per tier label (+ diagnostic dims /
  task_type for the shadow log) in the exact shape `Classifier.decide/2` consumes
- **Seam, non-breaking:** `router_config["backend"]` (`:infinity | :ortex`,
  default `:infinity`) dispatched inside `Classifier.score/2`; Infinity path
  untouched. `labels` become a **threshold ladder** (`class` + `min`, highest tier
  first); `parse_config` branches requirements by backend (ortex needs `model`, not
  `classifier`). Backend selectable via seed/config — admin UI toggle deferred to
  the cutover sprint (no UI work, so no `joby_kit.lint` gate)
- **Validation harness:** a mix task / test that runs a fixed prompt set on CPU
  through the `:ortex` backend, asserts **decision parity** on the §10 set **and the
  code-nuance cases** (string-reverse → edge, multi-file refactor → deep — the
  regression topic-entailment failed), and **logs p50/p95 latency** (single pass;
  target ≤ the ~45ms Infinity LAN hop)
- **DoD extra:** dep chain compiles clean **on the build host** (not the VM); export
  passed the equivalence gate (or fell back, recorded); a real chat request through a
  `:classify` alias with `backend: :ortex` produces a `route.class` with **no
  Infinity/GPU call** (verified — no outbound classify); `LocalClassifier`
  unit-tested against the bundled real ONNX (deterministic scores + code-nuance
  cases); latency logged under budget; the `:infinity` path is byte-for-byte
  unchanged (non-regression test)

### [x] S16 — Routing settings (system-level classifier)
See [DESIGN-routing-settings.md](./DESIGN-routing-settings.md).
Depends on S13 (classifier seam) + S15 (`:ortex` backend). Lift the classifier
config out of `aliases.router_config` into **one system-level "Routing"
setting**, with an `/admin/routing` UI to choose the engine (**local Ortex |
remote Infinity**) + model, the score weighting, and the tier ladder, and to
test a prompt — so a routed alias only **opts in** (`router` + `router_mode`)
and inherits the system classifier. Also retires the S15 alias-form clobber bug.
- **Schema/migration:** `routing_settings` singleton (`backend`, `classifier`,
  `model`, `score`, `labels` ladder, `default_class`, `input`, `timeout_ms`);
  add `aliases.router_mode` (`:shadow|:enforce`); migrate then drop
  `aliases.router_config`; `Config.routing_config/0` cached in `:persistent_term`
- **Seam re-point (no inference change):** `Classifier.class_for/2` reads the
  system setting; `Gateway` mode reads `alias_.router_mode`; `score/2` dispatch,
  both backends, and `decide/2` untouched; `:infinity` decisions unchanged
- **`/admin/routing` LiveView:** Local|Remote engine control, model/classifier
  pick (+ holder load status), weighting + ladder editors, moved prompt-tester;
  JobyKit-compliant (`mix joby_kit.lint` green)
- **Alias form:** reduce to a `router` toggle + `router_mode` select + a link to
  Routing settings (removes `build_router_config/1` and the clobber)
- **DoD:** config in one system row; engine switch Local↔Remote in one control;
  alias form can't clobber; migration carries existing config with no behavior
  change; precommit + joby_kit.lint green

### [x] S17 — Agent control plane (operator-driven)
See [DESIGN-agent-management.md](./DESIGN-agent-management.md). Builds on the Model 2
spine (interim: `Agent` entity, channel ingest, slot-Providers, `/agents` read-only).
Turn the read-only `/agents` view into operator-driven control — load / unload / swap
the model resident in a host's slot from Airo — with **no** deployment, routing, or
placement coupling.
- **Resident slot state, first-class:** new `Airo.Agents.SlotState` (ETS, mirrors
  `Airo.Health`) holding `resident_model`/`revision`/`status`/`reason` from the
  push; `Ingest.register`/`slot` write it (and **drop** the deployment-health
  inference of the resident model), `host_down` clears it, every change broadcasts
  on PubSub
- **Control client** `Airo.Agents.Control` (HTTP → `control_url`, bearer =
  `agent_token`, short timeouts, tagged errors): `inventory/1`, `slots/1`, `gpu/1`,
  `load/3` (default profile), `unload/2`, `refresh_inventory/1`. **Control =
  request; state = push** — `load`/`unload` return "accepted," completion arrives as
  a `slot` push (`loading`→`up`|`failed`)
- **`/agents/:id` interactive:** per-slot Load (inventory picker) / Unload / Swap
  (interrupt warning) / Resync; inventory panel with provenance (revision); resident
  model from `SlotState`; controls disabled when the host is offline; live updates
  via the PubSub subscription (replaces the slot/GPU 10s timer)
- **Fixed decisions:** load is deployment-free; default profile only; naive swap (no
  drain); placement-on-dispatch is **S18**, provenance→Shelf is later (DESIGN §2, §7)
- **DoD extra:** with a live agent, an operator loads→swaps→unloads a slot and the
  resident model/revision/status update live with no deployment row written;
  `Airo.Agents.Control` tested against a stubbed Req plug (not a live agent)
- _Complete: `Airo.Agents.SlotState` (ETS) + `Ingest` write/clear/broadcast on a
  dedicated `agent_slots:<host_id>` topic; `Airo.Agents.Control` client (9 tests vs
  stubbed Req); `/agents/:id` Load/Swap/Unload/Resync + inventory picker, resident
  state from the push, offline guards. precommit + joby_kit.lint green (329 tests).
  Push→live-update verified end-to-end; happy-path load pending a reachable host._

### [x] S18 — Host capacity & memory-fit
See [DESIGN-agent-placement.md](./DESIGN-agent-placement.md). Builds on S17 (merged).
Make packing several models onto one host safe: surface memory headroom, estimate
whether a requested load fits, and **warn** before an over-budget load — no
auto-load, evict, or block.
- **`Airo.Agents.Capacity`** (pure, no I/O): `footprint_mb(size_bytes)`
  (`size_bytes × 1.2` margin), `headroom(gpu)` (`total/used/free_mb` or
  `:unavailable`), `assess(size_bytes, gpu, reclaim_bytes)` → `%{footprint_mb,
  free_mb, fits?}` (swap-aware; `fits?: :unknown` with no telemetry)
- **No new data:** `/inventory` already reports `size_bytes`; `agent.gpu` already
  carries `vram_total/used_mb`; `SlotState` knows the resident model — pure
  Airo-side arithmetic over what S17 ships
- **`/agents/:id`:** free/total headroom on the GPU panel; inventory picker shows
  per-model footprint + an advisory `won't fit` tag (swap-aware), fits-first sort;
  **Load stays enabled** (advisory). Degrades to footprint-only with no telemetry
- **Fixed:** footprint = weights × 1.2; advisory only (never block); budget = live
  telemetry. Automatic placement/eviction is **S19**; Spark unified-memory budget
  deferred (memory is reported differently there)
- **DoD extra:** `Capacity` unit-tested (footprint, headroom incl. `:unavailable`,
  empty-slot vs swap assess, no-telemetry `:unknown`); picker shows footprint +
  swap-aware warning; Load never blocked
- _Complete: `Airo.Agents.Capacity` (pure; 10 tests); `/agents/:id` shows
  free/total headroom + per-model footprint with a swap-aware advisory `won't fit`
  tag, fits-first; Load never blocked. precommit + joby_kit.lint green (341 tests).
  Verified live against jobycorp (2.8 GB free, 25.5 GB resident): swap reclaims the
  outgoing footprint so no false warning; empty-slot load of the same model
  correctly reports `fits?: false`._

### [x] S19 — Resident-model identity & provenance
See [DESIGN-agent-provenance.md](./DESIGN-agent-provenance.md). Depends on S17.
Make the agent's model identity canonical: a resident model carries its real id +
provenance and its serving-instance facts, so the Shelf is correct and a loaded
model's deployment reads `up` (today it reads `down`/"Avoid" while serving). The
agent already pushes the data — Airo-side only.
- **Two tiers, two homes:** *model provenance* (static — `revision`, `family`,
  `quant`, `size`, `ctx_max`; from `/inventory` joined by resident id) → `Model`;
  *serving instance* (runtime — `ctx`, `parallel`, `engine_build`; from the slot
  push, already shipping) → `SlotState`
- **`SlotState` + `Ingest`:** carry `ctx`/`parallel`/`engine_build` through; the
  agent slot view shows effective `ctx` of `ctx_max` · `parallel` · `engine_build`
  paired with `revision`
- **Reconciliation:** on register, join inventory by resident id → enrich the
  `Model` (canonical `upstream_model_id` = `repo:quant`, `revision`, `family`,
  `quantization`, `size`); identify the slot's deployment so health keys on
  identity not the raw string; **legacy repair** re-keys filename-named records via
  the GGUF `path` basename
- **Fixed:** agent identity canonical (`repo:quant`); provenance vs serving stay
  separate (config not rewritten from runtime); no agent change
- **DoD extra:** Model 13 / deployment 18 heal (`up`, provenance populated, "Avoid"
  clears); reconciliation + filename re-key unit-tested; Ingest health keys on
  identity
- _Complete: `Airo.Agents.Provenance.reconcile/4` (host_model_slot key,
  display_name = real name, revision/family/quantization/size enrichment, legacy
  filename re-key guarded to the slot provider, deployment linked by real-id or
  filename; 6 tests). `SlotState` carries ctx/parallel/engine_build; `Ingest`
  joins `/inventory` per register/slot and derives health by `model_id` identity.
  Verified live: jobycorp's model healed to `up`, host-qualified id, full
  provenance, guidance flipped Avoid→Candidate. precommit + joby_kit.lint green
  (347 tests). Deferred: serving-facts UI, repo-lineage grouping, revision×build
  perf attribution._

### [x] S20 — Slot configuration & reload
See [DESIGN-slot-config.md](./DESIGN-slot-config.md). Depends on S17 + S19. Let an
operator configure how a model is served on a slot — starting with the context
window — and load/restart it, from an always-visible model list with a config modal.
- **`Control.load/4` profile:** `POST /load {model, slot, profile}`; v1
  `profile = %{ctx: n}` (nils dropped). Configure = load the resident model into
  its slot with the new profile → the agent restarts it (interrupts in-flight)
- **`<.modal>` wrapper:** wrap daisyUI `<dialog class="modal">` as a registered
  composite (backdrop/Esc close, focus, reduced-motion); + preview
- **`/agents/:id`:** always-visible "Models on this host" list (online) — each
  model has **Load** (not resident) or **Configure** (resident); slots gain a
  Configure action. The **config modal** shows the context window **against
  `ctx_max`** (reuse the `meter` visual); Load → "Load model", Configure →
  "Restart with changes" with an interrupt note. Offline ⇒ read-only
- **Fixed:** v1 = `ctx` only (extensible); advisory bounds `1..ctx_max`; no drain
- **DoD extra:** Load sets a ctx and loads; Configure prefills current ctx and
  restarts; new ctx shows after the push; `<.modal>` lint-clean; `Control.load/4`
  profile unit-tested vs a stubbed Req plug
- _Complete: `Control.load/4` profile (nils dropped; 11 tests); `<.modal>` wrapper
  (registered + preview); `/agents/:id` shows an always-visible "Models on this
  host" list (Load/Configure per model, resident-tagged), a Context column on
  slots, and a config modal with the context window shown against `ctx_max` (meter
  signature). Load/restart fire async (90s timeout, off the LiveView) so the slow
  blocking `/load` doesn't freeze the page — the slot transitions via push.
  Verified live (jobycorp): modal prefills 65536, meter 65536/262144, copy/flow.
  349 tests, precommit + joby_kit.lint green. Deferred: profile keys beyond ctx,
  fast-rejection feedback on async load, drain-on-restart._

### [x] S21 — VRAM validation & context legibility
See [DESIGN-vram-validation.md](./DESIGN-vram-validation.md). Implements
airo_agent A4 (VRAM-fit) + A2 (legibility). Depends on S18 (capacity) + S20 (config).
Hard-block a context that won't fit VRAM before loading — over-commit segfaults
llama-server (KV `cudaMalloc` OOM) — and make ctx/parallel/KV-quant legible.
- **Calibrated VRAM** (no arch formula): `per_ctx = (vram_used − weights)/ctx_total`
  from live telemetry; `projected = weights + per_ctx × ctx_total'`; fits =
  `projected ≤ vram_total × 0.95`. Captures KV-quant/flash-attn/MTP implicitly
- **Two cases:** resident reconfigure → calibrated **hard block** (exact, the
  documented danger); cold load → weights-floor hard block + KV "not validated"
- **Groundwork:** `SlotState`/`Ingest` ingest `ctx_total` + `profile`
  (`resolved_profile`); `profile` preserved when a push omits it
- **`Capacity`:** `per_ctx_mb`, `project`, `validate` → `fits?: true|false|:cold`
- **UI:** A2 — slots/list/modal show "ctx per-request × parallel = total" + tags
  (KV `q8_0`, flash-attn, MTP); A4 — config modal projected-VRAM meter, submit
  **disabled** with a reason when over budget
- **Fixed:** hard limit (not advisory); 95% margin; calibrate not model
- **DoD extra:** an over-budget reconfigure is blocked with a reason; a fitting one
  allowed; `Capacity` projection/validation + cold-floor unit-tested
- _Complete: `Capacity.per_ctx_mb`/`project`/`validate` (calibrated; 15 tests incl.
  cold floor + over-budget); `SlotState`/`Ingest` carry `ctx_total` + `profile`
  (profile preserved across pushes). UI: slots show "ctx × parallel = total" + KV/
  flash-attn/MTP tags; config modal projects VRAM as the slider moves and **hard-
  blocks** (disabled submit + server guard) over the 95% budget. Verified live on
  jobycorp: at 146432 → 27.2/30.3 GB allowed; at max 262144 → 31.8/30.3 GB blocked
  ("reduce the context"). 354 tests, precommit + joby_kit.lint green. Deferred:
  per-model KV learning, parallel editing, agent-side pre-flight guard._

### [ ] S22 — Automatic placement & eviction (on dispatch)
Bumped from S18–S21. Depends on S18 (capacity) + S19 (identity) + S20 (profile) +
S21 (VRAM validation) + S17. The serving-path hook that, before serving a managed
provider, ensures the right model is resident — slot selection, VRAM/memory fit
(reusing `Airo.Agents.Capacity`), and what-to-evict policy. The open question in
airo_agent/DESIGN.md; only safe on a proven manual control plane + capacity +
canonical identity + VRAM validation.

---

## Status log

_Append one line per merge: `S0 merged <sha> — note`._

- S0 merged 9e4dc29 — Cloak vault + config-plane schemas (Provider/Deployment/Alias/ClientKey/Secret/UsageRecord), Airo.Config + Airo.Usage contexts, dev seeds; 39 tests, precommit green.
- S1 merged 11d60fd — Airo.Adapter behaviour + Context, Airo.Transport (Req/Finch wrapper, Airo.Finch pools), Airo.Registry, OpenAICompatible chat (non-streaming); 19 tests vs stubbed Req plug, precommit green.
- S2 merged 6bc978e — POST /v1/chat/completions (non-streaming): ClientKeyAuth plug, Airo.Gateway (resolve/authorize/select/dispatch), Params normalization v1, OpenAI-shaped errors; 74 tests + real-socket smoke, precommit green. (No live vLLM/Ollama available — real-model check pending a running backend.)
- S3 merged 092fc58 — SSE streaming: Adapter.stream/4 (reducer), Transport SSE parser over Req :into, OpenAICompatible.stream, Gateway resolve/run/run_stream + transparency, controller text/event-stream with x-gateway-* headers + gateway.metadata trailer + [DONE]; 81 tests + real-socket streaming smoke, precommit green.
- S4 merged a050d91 — Routing core: Airo.Runtime.Store (ETS), Airo.Health + Prober (preference signal, ~90s staleness), Airo.Routing (priority/weighted/round_robin, health re-sort, class/tools filters, fallback chain, strict route.binding pin), Gateway failover (5xx/timeout not 4xx; streaming pre-byte), served-candidate transparency; 105 tests + real-socket failover smoke, precommit green.
- S5 merged 5ca0bca — Capability breadth: generic Gateway.run dispatch; /v1/embeddings, /v1/models (scoped aliases), /v1/rerank, /v1/audio/{speech,transcriptions}; Anthropic adapter (Translate OpenAI↔Messages, claude-code OAuth refresh, chat+stream normalization), Infinity rerank/embed, Speaches audio; shared GatewayError/GatewayHeaders; 139 tests, precommit green. Each capability has an adapter + test.
- S6 merged d9e9c21 — Observability & config UI: async Airo.Usage + cost (Task.Supervisor), GatewayUsage wired into all controllers; OpenAPI at /openapi (open_api_spex); Oban + UsageRecord PruneWorker; JobyKit admin LiveViews under /admin (Providers/Deployments/Aliases+candidates/Keys/Usage); 150 tests, joby_kit.lint green.
- S7 completed operationally — incogito and orchester fully cut over; both now use Airo as the only gateway path to AI models, with app-specific orchestration remaining in the consumers.
- S8 merged 813d86a — realtime WebSocket proxy: Airo.Realtime (alias/concrete resolution, connect-time health routing, intent→capability), AiroWeb.RealtimeProxy (WebSock in / Mint.WebSocket out, transparent frame relay, pre-open buffering, session UsageRecord), RealtimeController + :realtime_api pipeline + GET /v1/realtime, GatewayError :unsupported_intent, mint_web_socket dep; 6 tests (resolution + relay against a real echo upstream) + verified against the REAL Speaches endpoint (session.created relayed back), precommit green (169 tests).
- S10 merged 190c042 — API docs: Swagger UI at /docs (OpenApiSpex.Plug.SwaggerUI over /openapi) + "Docs" nav link; enriched AiroWeb.ApiSpec with request/response schemas + examples, the route object (class/tools/vision), capabilities on /v1/models, /v1/classify, Error/Usage schemas, 401/404; 191 tests + /docs render test, joby_kit.lint green. (Interim work since S6, not numbered sprints: multi-valued deployment capabilities + vision routing, /v1/classify endpoint + adapter, health-visibility admin columns, release-based deploy to the airo VM.)
- S11 merged b15d2aa — Gateway observability: request trace ids in headers/SSE metadata/usage rows, structured gateway logs, failed-request accounting, usage admin filters + summaries + trace drilldown, provider/deployment health transition history; 195 tests, joby_kit.lint green.
- S13 merged d9c510b — Classification-driven chat routing: `aliases.router`/`router_config`, `Airo.Routing.Classifier` (Infinity deberta-zeroshot, option-B NLI pairs built client-side + batched, ordered thresholds, total/fail-open), `Gateway.alias_target/3` hook (enforce applies `route.class`, shadow logs from a detached task), readable `gateway.route.classified` log, and an operator routing-tuning UI on `/admin/aliases` (router/mode/classifier/labels+thresholds + a no-traffic prompt-test). v1 edge-vs-deep, shadow-first; live-calibrated against the real model. 276 tests, joby_kit.lint green.
- S14 merged fa6ba65 — Logging & traceability: `log_events` table + `Airo.Logs` (`record/1` off the hot path via the Task.Supervisor, `list/2` filters, `for_trace/1`, summary) + Oban prune; capture of route predictions (`Gateway.log_classified`) and health transitions (`Health.record_event` dual-write, leaving `health_events` + readers untouched); `/admin/logs` viewer (kind/level/range/alias/predicted_class/trace filters) + "Logs" nav; `/admin/logs/:trace_id` unified usage+logs timeline. `/usage` unchanged; capture async/fail-open. 285 tests, joby_kit.lint green.
- S16 merged f98724a — Routing settings (system-level classifier): lifted the classifier config out of per-alias `router_config` into one singleton `Airo.Config.RoutingSetting` (`backend`, `classifier`|`model`, `score` weighting, `labels` ladder, `default_class`, `input`, `timeout_ms`, `hypothesis_template`) edited at a new `/admin/routing` LiveView (Local Ortex | Remote Infinity engine switch, weighting + ladder editors, built-in prompt tester; joby_kit.lint clean). `Classifier.class_for/2` now reads `Config.routing_config/0` (+ public `classify/2`); `Gateway` mode reads `Alias.router_mode` (`:shadow|:enforce`); inference (both backends + `decide/2`) byte-for-byte unchanged. Migrations seed the singleton from the routed alias, add `aliases.router_mode`, and drop `aliases.router_config`; the alias form is reduced to a router on/off + mode toggle (removing the S15 clobber bug). 309 tests, precommit + joby_kit.lint green. Deferred: named/multi classifier profiles, per-alias ladder overrides.
- S20 merged 018ad1f — Slot configuration & reload: `Control.load/4` gains a launch profile (`opts[:profile]`, nils dropped, empty omitted → agent default); new `AiroWeb.CompositeComponents.modal` (daisyUI dialog; backdrop/Esc close; registered + previewed); `/agents/:id` now shows an always-visible "Models on this host" list (Load / Configure per model, resident-tagged), a Context column on slots, and a config modal with the context window shown against `ctx_max` (meter signature) — Load → "Load model", Configure → "Restart with changes" (interrupt note). Load/restart fire async (90s timeout, off the LiveView) since the agent's `/load` blocks until ready; the slot transition arrives by push, so the page never freezes. v1 config = `ctx` only. 11 control tests; precommit + joby_kit.lint green (349). Deferred: profile keys beyond ctx, fast-rejection feedback on async load, drain-on-restart.
- S19 merged c47a5b0 — Resident-model identity & provenance: adopt the agent's model identity as canonical (Airo-side). `Airo.Agents.Provenance.reconcile/4` keys `Model.upstream_model_id` on `host_model_slot` (`<host>_<real_id>_<slot>`), sets `display_name` = the real model name, enriches `revision`/`family`/`quantization`/`size` from `/inventory`, re-keys a legacy filename-named Model in place (guarded to the slot provider — external Models untouched), and links the slot's deployment by real-id or GGUF filename. `SlotState` carries `ctx`/`parallel`/`engine_build` from the push; `Ingest` joins inventory per register/slot and derives health by `model_id` identity, not a raw `model_name` compare (graceful identity-only when the control API is unreachable). Scoped to agent-managed providers; external (`agent_id` null) keep upstream-id identity + prober health. Verified live (jobycorp model healed to `up`, full provenance, Avoid→Candidate). 347 tests, precommit + joby_kit.lint green. Deferred: serving-facts UI, repo-lineage grouping, revision×engine_build perf attribution.
- S18 merged a1df865 — Host capacity & memory-fit: `Airo.Agents.Capacity` (pure — `footprint_mb` = `size_bytes × 1.2`, `headroom/1` from live telemetry or `:unavailable`, `assess/3` swap-aware with `fits?: :unknown` fallback; 10 tests). No agent change — reuses inventory `size_bytes` + `agent.gpu`. `/agents/:id` shows free/total headroom under the VRAM meter and a per-model footprint column with an advisory `won't fit` tag (swap-aware, fits-first); Load is never blocked. Advisory only; budget = live telemetry; Spark unified-memory budget deferred; automatic placement is S19. precommit + joby_kit.lint green, 341 tests.
- S17 merged 57a0b85 — Agent control plane (operator-driven): `Airo.Agents.SlotState` (ETS resident-slot state, `:airo_slots` table) fed by `Ingest` from each push and cleared on disconnect, broadcast on a dedicated `agent_slots:<host_id>` topic; `Airo.Agents.Control` HTTP client to `control_url` (bearer = agent_token, short-timeout acks, `load`/`unload` return `:accepted`; 9 tests vs stubbed Req); `/agents/:id` gains Load/Swap/Unload/Resync + an inventory picker, resident model read from the push (not inferred from deployments), controls disabled when the host is offline. Load is deployment-free; default profile; naive swap. precommit + joby_kit.lint green, 329 tests. Deferred: automatic placement-on-dispatch (S18), provenance→Shelf, profile editing, drain-on-swap.
- S15 merged 6973c4e — Local ONNX routing classifier (Ortex, on-CPU): `{:ortex,:tokenizers,:nx}` native chain (Rust on the build host; NIF+ORT+model ship in the release tarball); `Airo.Routing.LocalClassifier` + boot Holder (loads ONNX session+tokenizer once into `:persistent_term`, warmup+contract assert, fail-open `:model_unavailable`); `Classifier.score/2` dispatch on `router_config.backend` (`:infinity` default, byte-for-byte unchanged | `:ortex`), `parse_config` branched, labels now a threshold ladder routing on a **graded complexity score** (NVIDIA `prompt-task-and-complexity-classifier`, deberta-v3-base) not topic entailment — fixes code-as-binary; `mix airo.fetch_model` (committed manifest: rev+shas+contract, gitignored binaries) + `mix airo.validate_classifier`. Export gate PASS (Δ~1e-6); 7/7 decision parity incl. code-nuance; CPU p50 44ms/p95 80ms (~parity with Infinity LAN, zero GPU). Validation-only: `:infinity` stays default, `:ortex` opt-in via config/DB. 301 tests, precommit green. Deferred: INT8, fine-tune, enforce flip, ORT thread-pinning, and a system-level routing-settings UI (S16).
