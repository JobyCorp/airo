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
  5. Speaches: speech/transcription model metadata and audio-specific latency posture
  6. Provider pages: local runtime inventory and currently loaded/running models,
     so machine-level capacity and duplicate failover copies are visible
  7. Evaluation layer: compare provider copy/version cohorts using existing
     `UsageRecord` latency/error/fallback/cost groups before adding subjective
     quality scoring
- **DoD extra:** given two deployments of the same model on different providers,
  the shelf shows them as one model with separate operational rows and aggregate
  performance; updating a model version creates visible before/after comparison
  data from `UsageRecord` without breaking existing gateway calls

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
