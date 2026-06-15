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

### [ ] S7 — Consumer migration
- incogito: repoint `base_url` → Airo; map assignments to single-candidate aliases
- orchester: delete resolver, repoint dispatch, translate strict pins → `route.binding`;
  keep Sink / agent loop / `:queued` Oban app-side
- **DoD extra:** both apps green against Airo

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
