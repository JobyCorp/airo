# Airo

An AI gateway in Elixir/Phoenix: **one configuration plane and one
OpenAI-shaped API surface** in front of a fleet of model backends — local
(llama.cpp, vLLM, Ollama, LM Studio, Infinity, Speaches) and cloud (OpenAI,
Anthropic).

Consumers point their OpenAI client's `base_url` at Airo and stop caring which
box, engine, or provider actually serves the request. Airo owns routing,
failover, health, secrets, usage attribution, and — for hosts running the
companion agent — model load/unload on the GPU.

```
   your apps ─┐                        ┌─ vLLM / llama.cpp / Ollama / LM Studio / OpenAI
              ┼──▶  Airo gateway  ─────┼─ Anthropic Messages + OAuth   (normalized)
              ┘     OpenAI-shaped      ├─ Speaches  /v1/audio/*
                    front door         └─ Infinity rerank → /v1/rerank (normalized)
```

## What it does

- **OpenAI-compatible front door** — chat (streaming + non-streaming),
  embeddings, rerank, classify, audio speech/transcription, models, and a
  realtime WebSocket proxy.
- **Routing** — priority / weighted / round-robin candidate selection with
  health re-sorting, capability and class filters, strict pins, and failover
  on upstream 5xx or transport errors (never on a 4xx; streaming only fails
  over before the first byte).
- **Classification-driven tiering** — an optional router scores each prompt for
  complexity and picks a model class from a threshold ladder. Two backends: a
  remote Infinity model, or a local ONNX DeBERTa run on CPU via Ortex.
- **Normalization** — non-OpenAI upstreams (Anthropic Messages + OAuth,
  Infinity rerank) are translated behind the OpenAI shape, and per-provider
  parameter quirks are normalized so consumers stop special-casing them.
- **Agent control plane** — for hosts running
  [`airo_agent`](https://github.com/JobyCorp/airo_agent), Airo sees resident
  slots, engine build, context config, and VRAM telemetry, and can load, swap,
  reconfigure, or unload models. Loads are validated against a calibrated VRAM
  model so an over-budget context can't be launched.
- **Observability** — per-request trace ids in headers, SSE metadata, and usage
  rows; structured gateway logs with a per-trace timeline; usage and cost
  attribution per client key; Prometheus exposition at `/metrics`.
- **Secrets at rest** — provider credentials are Cloak-encrypted in Postgres.

## Endpoints

Inference (`Authorization: Bearer <client key>`):

| Method | Path |
|---|---|
| `POST` | `/v1/chat/completions` (SSE when `stream: true`) |
| `POST` | `/v1/embeddings` |
| `POST` | `/v1/rerank` |
| `POST` | `/v1/classify` |
| `POST` | `/v1/audio/speech`, `/v1/audio/transcriptions` |
| `GET`  | `/v1/audio/voices`, `/v1/models` |
| `GET`  | `/v1/realtime` (WebSocket proxy) |

Management (requires a key scoped `management` — these expose host names and
upstream base URLs):

| Method | Path |
|---|---|
| `GET` | `/v1/serving`, `/v1/serving/health` |
| `GET` | `/v1/usage` |
| `GET` | `/metrics` (Prometheus text) |

Browser: `/admin/*` (models, providers, deployments, aliases, agents, keys,
routing, usage, logs), `/docs` (Swagger UI over `/openapi`), and `/design` +
`/custom-designs` for the [JobyKit](https://github.com/jobycorp/joby_kit)
component manifest.

## Getting started

Requires Elixir 1.19 / OTP 28 and PostgreSQL.

```bash
mix setup          # deps, database create + migrate + seed, assets
mix phx.server     # or: iex -S mix phx.server
```

Then visit [`localhost:4000`](http://localhost:4000). The dev seeds create a
local provider, a chat deployment, a `chat-standard` alias, and a `dev` client
key — the key is printed once during `mix setup`, so save it:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $AIRO_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"chat-standard","messages":[{"role":"user","content":"hi"}]}'
```

To use the local ONNX classifier, fetch its weights first (they are never
committed):

```bash
mix airo.fetch_model        # downloads against the committed rev + sha manifest
mix airo.validate_classifier
```

Before opening a PR:

```bash
mix precommit          # compile --warnings-as-errors, deps.unlock, format, test
mix joby_kit.lint      # UI component contract — required for any .heex change
```

## Configuration

Runtime config (`config/runtime.exs`) reads:

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection (required in prod) |
| `SECRET_KEY_BASE` | Phoenix signing (required in prod) |
| `CLOAK_KEY` | Vault key for encrypted provider secrets (required in prod) |
| `PHX_HOST`, `PORT`, `PHX_SERVER` | Endpoint host/port; `PHX_SERVER` starts the server in a release |
| `AIRO_AGENT_TOKEN` | Bearer token for the `airo_agent` control API |
| `POOL_SIZE`, `ECTO_IPV6`, `DNS_CLUSTER_QUERY` | Standard Phoenix/Ecto knobs |

Providers, deployments, aliases, routing settings, and client keys are database
state, managed from `/admin` — not config files.

## Deploying

`bin/deploy-docker.sh` builds a prod release inside an `ubuntu:24.04`
container, ships it over SSH, migrates, and restarts the service. Build the
release in the container even if it seems unnecessary: a natively built release
links your host's glibc and will not boot on the target. Read
[`DEPLOY.md`](./DEPLOY.md) before deploying — both scripts stop the service and
overwrite the install directory with no rollback.

## Docs

- [`docs/design/`](./docs/design/) — architecture reference
  ([`DESIGN.md`](./docs/design/DESIGN.md) is the entry point) and per-feature
  design notes
- [`docs/sprints/`](./docs/sprints/) — sprint process, scope, and
  [`STATUS.md`](./docs/sprints/STATUS.md), the merge log
- [`AGENTS.md`](./AGENTS.md) / [`CLAUDE.md`](./CLAUDE.md) — conventions for
  coding agents working in this repo
- [`airo_client`](https://github.com/JobyCorp/airo_client) — Elixir client SDK

## License

MIT — see [LICENSE](./LICENSE).
