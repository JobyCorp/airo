# Airo — Design

> A single configuration point and API surface for distributed AI model backends.
> Extracted from the shared model-dispatch layer that drifted between
> [`orchester`](~/orchester) and [`incogito`](~/incogito).

Status: **design** (no implementation yet). This document is the reference;
code follows it.

---

## 1. Thesis

orchester and incogito grew nearly identical AI backends — provider connections,
capability-based routing, OpenAI-compatible dispatch, Cloak-encrypted secrets,
per-call telemetry. incogito's version is a hand-ported *subset* of orchester's
("only the bones, for simplicity"). The two have since **drifted**.

Airo exists to be the **single source of truth both apps converge back onto**, so
the model can't drift again. It owns the provider/routing/normalization schema;
the apps become thin clients. Neither app owns the dispatch model anymore — Airo
does.

This is the LLM-gateway / model-router shape (LiteLLM / OpenRouter), in
Elixir/Phoenix — which is a strong fit: connection pooling, fan-out, streaming,
supervision, and health tracking are all OTP's home turf.

## 2. Goals / Non-goals

**Goals**

- One **configuration plane** for every model backend (providers, models, routing,
  secrets, client keys, usage).
- One **API surface** for OpenAI-shaped requests, with streaming.
- Multi-provider **routing**: weighting, health-awareness, fallback, strict pins.
- **Normalize** non-OpenAI upstreams (Anthropic Messages+OAuth, Infinity rerank)
  behind the OpenAI-shaped front door.
- **Param normalization** so consumers stop special-casing per-provider quirks.
- Per-consumer **auth + usage/cost attribution**.

**Non-goals**

- No app-specific concerns. orchester's `Sink`, agent loop, `:queued`/Oban
  dispatch, conversations; incogito's Riser/`send_update` — **all stay in the
  apps.** Airo never learns what a conversation is.
- No privacy/PII scrubbing layer. (incogito = "in thought", not "incognito".)
- Not a shared in-process library. Airo is a **standalone service**; the network
  hop is a non-issue because consumers keep their streaming sinks local and just
  consume Airo's SSE.

## 3. Background — what the two apps have today

| | orchester | incogito |
|---|---|---|
| Stack | Elixir umbrella, per-package dispatchers | Elixir/Phoenix, single adapter |
| Routing | Resolver: capability + class (edge/standard/deep/cloud), 90s health signal, **strict binding pins** (ORC-073), fallback chain | **None** — one global `(connection, model)` per capability |
| Dispatch modes | `:sync` / `:stream` / `:queued` (Oban) | sync + stream |
| Backends | vLLM, Ollama, LM Studio, Infinity, Anthropic (bespoke SSE + OAuth), OpenAI, Speaches | same set via one OpenAI-compatible adapter + Req for rerank/voice/comfy/searxng |
| Transport | `openai_ex` (Finch) + Req; hand-parsed Anthropic SSE | `openai_ex` (Finch) + Req |
| Secrets | Cloak; cloud accounts w/ OAuth refresh | Cloak vault; `api_key_secret_id` |
| Telemetry | Oban queue throttle, no per-call log | **Runlog** (trace_id, tokens, latency, outcome) |

orchester's `dispatch/{resolver,adapter,chat,registry}` + the per-package
dispatchers **already are** the gateway core. Airo lifts that out and puts an
OpenAI-shaped front on it; incogito's model is the degenerate case of Airo's.

## 4. Architecture

```
   orchester ─┐                         ┌─ vLLM / Ollama / LM Studio / OpenAI  (OpenAI-compat)
   incogito  ─┼──▶  Airo gateway  ──────┼─ Anthropic Messages + OAuth          (normalized)
   (future)  ─┘     OpenAI-shaped       ├─ Speaches  /v1/audio/*               (OpenAI-compat)
                    front door          └─ Infinity rerank → /v1/rerank        (normalized)
```

- **Front door**: OpenAI-shaped HTTP. Consumers repoint their `openai_ex`
  `base_url` at Airo.
- **Extend & enhance**, not married to the shape: vanilla OpenAI clients keep
  working; opt-in extensions carry richer intent in and richer metadata out.
- **Normalizing gateway**: pluggable backend adapters; even non-OpenAI upstreams
  are presented OpenAI-shaped.
- Consumers keep their bespoke layers. orchester deletes its resolver and calls
  Airo; its `Sink` stays local and consumes Airo's SSE exactly as it consumes
  vLLM's today.

## 5. API surface

OpenAI-shaped endpoints:

- `POST /v1/chat/completions`  (streaming + non-streaming)
- `POST /v1/embeddings`
- `GET  /v1/models`            (unified, aggregated across healthy providers)
- `POST /v1/audio/speech`
- `POST /v1/audio/transcriptions`
- `POST /v1/rerank`           (Jina/Cohere-compat shape; OpenAI has none)

Plus an admin/config surface (LiveView + JSON) and an OpenAPI spec
(`open_api_spex`).

### 5.1 Extension mechanisms — layered by opt-in

**1. `model` is a logical alias *or* a concrete deployment id (zero opt-in).**
`model: "chat-deep"` / `"embed-fast"` resolves via policy to a concrete
`(provider, model)`. If the name isn't an alias, it falls back to a concrete
deployment **model id** (e.g. `"BAAI/bge-m3"`) for the request's capability,
health-ordered as failover candidates — so consumers can keep sending the real
model ids they already store. Aliases win on a name collision. Pure OpenAI wire;
works from any SDK. `GET /v1/models` lists both (key-scoped).

**2. A `route` extension object in the body (opt-in, valid JSON).**
`openai_ex` forwards unknown body keys, so power-cases ride along; strict clients
ignore `route`:

```json
{
  "model": "chat-deep",
  "messages": [...],
  "route": {
    "class": "deep",
    "tools": true,
    "location": "local",
    "binding": "vllm:qwen3.5-9b",
    "fallback": ["chat-standard"]
  }
}
```

`route.binding` is orchester's **strict pin**: serve that deployment or return
`selected_binding_unavailable` — never silently substitute (preserves ORC-073).
Header equivalents (`x-route-class`, …) exist as a fallback for proxies that
mangle bodies; body is primary.

**3. Transparency metadata out (opt-in to read).**
Responses stay OpenAI-shaped, but Airo reports which concrete provider/model
served, whether a fallback fired, and latency — via `x-gateway-*` response
headers and an SSE trailing event for streams. Feeds observability + usage
without breaking response parsers.

## 6. Backend adapters & normalization

Each upstream is an adapter implementing a small behaviour
(`chat / stream / embed / rerank / speech / transcribe`), mirroring orchester's
existing adapter contract.

- **OpenAI-compatible** (vLLM, Ollama, LM Studio, OpenAI, Speaches): near
  passthrough.
- **Anthropic**: adapter accepts `/v1/chat/completions`, translates to the
  Messages API, manages **claude-code OAuth** token refresh + beta headers, emits
  OpenAI SSE out. (Reasoning → `delta.reasoning_content`; tools → `delta.tool_calls`.)
- **Infinity rerank**: exposed as `/v1/rerank`.

SSE normalization: all streams come out as OpenAI deltas. OpenAI's delta format is
expressive enough — `delta.tool_calls` for tools, `delta.reasoning_content` for
thinking traces (incogito already folds this) — so orchester's richer typed
events survive normalization.

## 7. Param normalization

**Canonical vocabulary = OpenAI param names + a small set of gateway extensions.**
The request *is* the canonical form (front door is already OpenAI-shaped), so the
common OpenAI→OpenAI path pays no translation cost. Each adapter implements
`translate_params(canonical, deployment_meta) -> provider_native`.

Interesting translations:

- `max_tokens` → `max_completion_tokens` / `max_new_tokens`
- **`reasoning_effort: low|medium|high`** → Anthropic `thinking.budget_tokens`,
  vLLM/Qwen `chat_template_kwargs.enable_thinking`, DeepSeek-style flags. One knob,
  N translations — this is where normalization earns its keep.
- stop sequences, temperature/top_p ranges, penalties — minor clamps/renames.

**Layered defaults, resolved at request time:** `provider < deployment < alias <
request`. A `chat-deep` alias can carry `reasoning_effort: high`; a request still
overrides.

**Escape hatches so normalization never traps you:**

- `provider_params: { ... }` — raw passthrough, bypasses translation.
- Unknown-param policy: **passthrough** by default (forward unrecognized keys
  untouched — most upstreams are OpenAI-compat and accept them). Strict-drop is
  opt-in per provider.

## 8. Configuration data model

The "one place to configure everything." A unification of both apps' schemas;
structurally the **full orchester model**, with incogito's collapsed model as the
degenerate case.

Key structural decision: **separate `Model`, `Deployment`, and `Alias`**.
Model is the durable artifact/version identity operators evaluate; Deployment is
the runnable copy of that model on a provider/machine; Alias is the routing
policy consumers call. **Health and usage still attach to Deployment** (the
thing that fails / costs money), while the Model Shelf aggregates those signals
back to the model/version level.

```
Provider          ← physical upstream  (orchester Install / incogito Connection)
  type/adapter      vllm | ollama | lmstudio | openai | anthropic | speaches | infinity
  base_url
  credential_ref  → Secret             (nullable for keyless LAN)
  auth_kind         none | api_key | oauth   (oauth tokens live in Secret)
  default_params    ← provider layer
  enabled

Model             ← managed artifact/version identity  (Model Shelf)
  display_name      "Qwen 3.5 9B"
  family            "qwen"
  upstream_model_id "qwen3.5-9b"
  version/revision/quantization/size
  status            evaluating | preferred | deprecated | disabled
  notes

Deployment        ← runnable model copy on a provider  (orchester CapabilityBinding)
  provider_ref
  model_ref       → Model
  model_name        "qwen3.5-9b"
  capability        chat | embeddings | rerank | speech | transcription
  class             edge | standard | deep | cloud
  tool_use          bool
  context_window
  pricing           in/out per-1k       (feeds cost attribution)
  default_params    ← deployment layer
  provider_metadata native local-runtime metadata, scoped to this provider copy

Alias             ← logical handle consumers call  ("chat-deep")
  capability
  candidates        [ {deployment_ref, weight, priority}, ... ]
  strategy          weighted | priority | round-robin
  fallback          [alias_ref, ...]
  default_params    ← alias layer

ClientKey         ← consumer auth  (NEW — didn't exist in-process)
  hashed_key, name  ("orchester" / "incogito")
  allowed_aliases   scope (or *)
  enabled           (rate_limit → v2)

Secret            ← Cloak vault  (port from either app, identical)

UsageRecord       ← promoted incogito Runlog
  ts, client_key_ref, alias, deployment_ref, capability,
  tokens_in/out, latency_ms, outcome, finish_reason, fallback_used, cost
  model/version snapshot copied at write time for before/after comparisons
```

Mapping from today's schemas:

- orchester `Install` / incogito `Connection` → **Provider**
- orchester `CapabilityBinding` → **Deployment**
- orchester `CloudAccount` → **Provider** (cloud) + **Secret** (tokens)
- incogito `CapabilityAssignment` → a degenerate **Alias** (one candidate, no policy)
- both apps' `Secret` → **Secret**
- incogito `Runlog` → **UsageRecord**

**Health is runtime, not config.** Per-Deployment status / latency lives in
ETS / `:persistent_term` (a periodic prober, ~90s staleness threshold from
orchester), snapshotted to DB only for the UI. Kept out of the config tables.

## 9. Routing

Airo **owns** routing; orchester delegates (deletes its resolver) and only pins
via `route.binding` when it needs strict-selection behavior.

- Alias → candidate Deployments, filtered by health + class + tool_use + location.
- Strategy: weighted / priority / round-robin among healthy candidates.
- **Failover/retries**: on upstream 5xx/timeout, advance the fallback chain.
- **Strict pin** (`route.binding`): serve that Deployment or
  `selected_binding_unavailable` — never substitute.
- Health threshold is a **preference signal**, not a hard gate (don't refuse a
  freshly-reloaded dev endpoint).

## 10. Auth, usage, observability

- **Client keys**: Airo-issued, hashed, scoped to allowed aliases. (Gateway→
  upstream auth is separate, via Provider `credential_ref`.)
- **Usage + cost attribution**: every call → `UsageRecord` (promoted Runlog),
  cost computed from Deployment pricing. The reason this matters the moment two
  apps share a pool.
- **Model Shelf**: admin model-management layer over deployments. It shows one
  model/version with all runnable deployment copies across machines, aggregate
  and per-deployment latency/error/fallback/cost, recent traces, health
  transitions, alias participation, and version-performance groups. Routing
  remains explicit in Alias; the shelf explains which models are safe to lean on
  and whether version changes improved observed behavior.
- **Local provider management**: provider-specific management APIs are focused
  on local runtimes first. Ollama exposes native catalog/inspect/pull/runtime
  APIs and is the reference implementation: a deployment-level sync stores
  provider-native metadata (`family`, `families`, `format`, `parameter_size`,
  `quantization`, `architecture`, `context_window`, `runtime_version`,
  `running`, and raw inspect/runtime payloads) while updating the shared model
  identity only for stable metadata such as family, quantization, and size.
  LM Studio uses its native `/api/v1/models` and download endpoints for
  catalog/runtime/load-state discovery; vLLM uses `/v1/models` plus Prometheus
  `/metrics` for served-model/context/runtime posture. Infinity uses `/models`
  plus `/metrics` for embeddings/rerank/classify metadata, queue stats, backend,
  and endpoint posture. Speaches uses `/v1/models`, `/v1/models/{id}`, and
  `/api/ps` for speech/transcription task, language, voice, sample-rate, and
  loaded-model metadata. Cloud providers remain catalog-only/backlog for model
  management.
- **Transparency**: `x-gateway-*` headers + SSE trailing event (see §5.1).
- Rate limits: **v2**.

## 11. Scope

**v1**

- Routing core (alias resolution, weighting, health-aware, fallback, strict pin)
- Failover / retries
- Usage + cost attribution
- Per-client-key auth
- Unified `/v1/models`
- Param normalization

**v2**

- Per-key rate limits
- Caching (embeddings cache; prompt/response cache)

## 12. Consumer migration

- **incogito first** (trivial): already single OpenAI-compatible adapter — repoint
  `base_url` at Airo, map its one-model-per-capability assignments to single-
  candidate Aliases. Gains routing/fallback for free; loses nothing.
- **orchester second** (the real work): repoint dispatch at Airo, **delete the
  resolver**, translate strict-binding pins to `route.binding`. Keep `Sink`,
  agent loop, `:queued`/Oban entirely app-side — they consume Airo's SSE.

## 13. OTP shape (sketch — to be detailed)

- `Airo.Gateway` — request entry, alias resolution, param normalization, dispatch.
- `Airo.Adapter` — behaviour; one impl per upstream type.
- `Airo.Registry` — adapter type → module.
- `Airo.Health.Prober` — periodic probes → ETS/`:persistent_term`; UI snapshots.
- **Finch pools per Provider** (`base_url`); Req for non-streaming bespoke calls.
- `Airo.Usage` — async `UsageRecord` writes (don't block the response path).
- Config plane: Ecto/Postgres + Cloak vault; LiveView admin (JobyKit wrappers) +
  `open_api_spex`.

## 14. Dependencies

We do **not** adopt `openai_ex` (used by both source apps). Airo is a normalizing
gateway, not an app calling one provider — it wants direct control over SSE
passthrough, header injection, and transparency trailers. Upstream transport is
**our own thin wrappers over Req/Finch**, one transport for both OpenAI-compatible
and bespoke (Anthropic, Infinity) adapters.

Added to the scaffold:

| Dep | Version | Why |
|---|---|---|
| `cloak` | `~> 1.1` | Secret vault (both apps: 1.1.4) |
| `cloak_ecto` | `~> 1.3` | `EncryptedBinary` Ecto type (1.3.0) |
| `finch` | `~> 0.22` | explicit, for per-Provider named pools (§13) |
| `open_api_spex` | `~> 3.21` | OpenAPI spec; new — neither app had it |
| `oban` | `~> 2.23` | housekeeping only: `UsageRecord` prune + health snapshots |

Reused from the scaffold: `req`, `ecto_sql`/`postgrex`, `jason`, `telemetry_*`,
`bandit`, `phoenix_live_dashboard`. `plug_crypto` arrives transitively
(constant-time API-key compare — no bcrypt; keys are high-entropy → SHA-256).
**No `openai_ex`.** Rate limiting (`hammer`/`ex_rated`) is v2.

## 15. Open questions / next steps

- [x] Detail the OTP supervision tree and the `Airo.Adapter` behaviour contract.
      *(S1: `Airo.Adapter` behaviour + per-capability optional callbacks; S4:
      `Airo.Runtime.Store`/`Airo.Health.Prober` in the tree.)*
- [x] Streaming: confirm OpenAI-delta normalization covers every orchester event
      (tool-call argument streaming, Anthropic content-block boundaries).
      *(S3: OpenAI-compatible passthrough; S5: Anthropic `stream_event/1` maps
      content-block deltas → `content`/`reasoning_content`/`tool_calls`.)*
- [ ] Migration mechanics for orchester's `:queued`/Oban path (it calls Airo from
      a worker; nothing special, but confirm error/retry semantics).
- [ ] Homelab ops: deploy as a Phoenix release behind Traefik
      (`airo.local.joby.gg`) + its own Postgres; client keys for orchester/incogito.
- [ ] Pricing source for cost attribution (manual per-Deployment vs a price feed).

**Anthropic claude-code OAuth** is configurable (the exact token endpoint /
client id / beta header are deployment-specific):

```elixir
config :airo, Airo.Adapters.Anthropic,
  version: "2023-06-01",
  beta: "oauth-2025-04-20",
  oauth_token_url: "https://console.anthropic.com/v1/oauth/token",
  oauth_client_id: System.get_env("ANTHROPIC_OAUTH_CLIENT_ID")
```
