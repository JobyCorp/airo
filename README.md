# Airo

An AI gateway in Elixir/Phoenix. It puts **one configuration plane and one
OpenAI-shaped API** in front of a fleet of model backends — local (llama.cpp,
vLLM, Ollama, LM Studio, Infinity, Speaches) and cloud (OpenAI, Anthropic).

Point an OpenAI client's `base_url` at Airo and stop caring which box, engine,
or provider serves the request.

```
   your apps ─┐                        ┌─ vLLM / llama.cpp / Ollama / LM Studio / OpenAI
              ┼──▶  Airo gateway  ─────┼─ Anthropic Messages + OAuth   (normalized)
              ┘     OpenAI-shaped      ├─ Speaches  /v1/audio/*
                    front door         └─ Infinity rerank → /v1/rerank (normalized)
```

## What it does

- **OpenAI-compatible surface** — chat (streaming and not), embeddings, rerank,
  classify, audio speech/transcription, models, and a realtime WebSocket proxy.
- **Routing and failover** — priority, weighted, or round-robin candidate
  selection, re-sorted by live health, with capability filters, strict pins, and
  failover on upstream 5xx or transport errors.
- **Prompt-complexity tiering** — an optional router scores each prompt and
  picks a model class from a threshold ladder, using either a remote model or a
  local ONNX classifier on CPU.
- **Normalization** — non-OpenAI upstreams and per-provider parameter quirks are
  translated behind the OpenAI shape, so consumers stop special-casing them.
- **Model control plane** — on hosts running a companion agent, Airo sees
  resident slots and VRAM telemetry and can load, swap, reconfigure, or unload
  models, refusing launches that won't fit.
- **Operations** — per-request trace ids through headers, streams, and usage
  rows; per-key usage and cost attribution; Prometheus metrics; provider
  credentials encrypted at rest.

Everything is managed from a web admin UI; providers, routes, and keys are
database state, not config files. Interactive API docs ship at `/docs`.

## Getting started

Requires Elixir 1.19 / OTP 28 and PostgreSQL.

```bash
mix setup          # deps, database, seeds, assets
mix phx.server     # then visit localhost:4000
```

The seeds create a provider, deployment, `chat-standard` alias, and a dev client
key (printed once — save it):

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $AIRO_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"chat-standard","messages":[{"role":"user","content":"hi"}]}'
```

## Docs

- [`docs/design/DESIGN.md`](./docs/design/DESIGN.md) — architecture reference
- [`docs/sprints/`](./docs/sprints/) — how the project is built, and what shipped when
- [`DEPLOY.md`](./DEPLOY.md) — releases and deployment
- [`airo_client`](https://github.com/JobyCorp/airo_client) — Elixir client SDK

## License

MIT — see [LICENSE](./LICENSE).
