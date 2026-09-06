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

## Build details

Three pieces sit beside the Phoenix app. Each has its own repo or toolchain,
and each has one thing that is easy to get wrong.

### Local ONNX classifier (prompt-complexity routing)

The routing tier can score prompts **on CPU, in-process**, with no GPU and no
network call. It runs NVIDIA's `prompt-task-and-complexity-classifier`
(DeBERTa-v3-base) through [`ortex`](https://hex.pm/packages/ortex) (ONNX Runtime
as a Rust NIF) and the `tokenizers` NIF; both compile with the Rust toolchain,
so **`rustup` is a build dependency** wherever the app is built (dev machines and
the release builder image alike).

- **The model files are not in git.** `priv/models/` is gitignored. A committed
  manifest in `Mix.Tasks.Airo.FetchModel` records the Hugging Face revision,
  the sha256 of `model.onnx` and `tokenizer.json`, and the model's output
  contract (input names, output shapes, the complexity-dimension order and the
  task-type label map). Put the files in place with:

  ```bash
  mix airo.fetch_model nvidia-prompt-task-complexity --from DIR   # verifies checksums
  mix airo.validate_classifier                                    # decision parity + CPU latency gate
  ```

  With no files present the app still boots: the classifier records itself
  `:unavailable` and routing **fails open** to the configured default class.

- **Export is a separate Python step**, in the sibling `onnx-export` repo
  (`export.py`): it folds the model's post-processing (`process_logits`) into
  the ONNX graph so the NIF returns final scores, pins the HF commit, and writes
  the two files the fetch task expects. The tokenizer is capped at **128 tokens**:
  the tail of a long prompt does not change the routing decision, and the cap
  takes p95 from about 400 ms to about 60 ms.

- **The release must carry the files.** `bin/deploy-docker.sh` copies
  `priv/models/` from the working tree into the staged source and refuses to
  build if it is empty; a release without them serves, but never classifies
  locally. The admin's routing page switches the backend between the local
  `ortex` engine and a remote Infinity classifier.

### Host agent (`airo_agent`)

GPU serving hosts run [`airo_agent`](../airo_agent), a small OTP release that
**controls** engines (llama.cpp, vLLM) and never sits on the inference path:
it loads, swaps and unloads models in fixed serving slots, scans the local
Hugging Face cache for provenance, and pushes host and slot state to Airo.

- **Two channels, two directions.** The agent is the *client*: it connects to
  Airo's `/agent` WebSocket (`AiroWeb.AgentSocket`) and pushes `register`
  heartbeats and `slot` transitions. Airo *commands* the agent over its HTTP
  control API (`control_url`, port 4400). Inference goes straight to the slot's
  `base_url`. Auth is one optional shared bearer, `AIRO_AGENT_TOKEN`, on both
  legs; unset means the socket accepts any host, which is the LAN posture today.
- **One controller, any number of observers.** The agent's `AIRO_SOCKET_URL` is
  the single Airo allowed to load and unload; `AIRO_OBSERVER_SOCKET_URLS` lists
  Airos that receive the same stream but are refused control. This is how a dev
  Airo on a workstation sees the real fleet and can route to it without being
  able to disturb it. Airo records each host's role and disables the controls
  for observed hosts.
- **Liveness is more than a socket.** Airo tracks connect and disconnect via
  Presence, calls a connected host **stale** when its heartbeat has been silent
  past the configurable window (default 45 s), and records every transition in
  `host_events`, on the agent page, and in Prometheus gauges.
- **Build and deploy** live in the agent repo: a multi-arch container build
  (x86 and arm64 DGX Spark hosts), one host at a time, because restarting an
  agent drains every engine it owns. The vLLM slot wrapper is bash 3.2 safe so
  its tests also run on macOS.

Design notes: `docs/design/DESIGN-agent-management.md` and
`docs/design/DESIGN-agent-lifecycle-and-roles.md`.

### Elixir client (`airo_client`)

[`airo_client`](https://github.com/JobyCorp/airo_client) is the server-to-server
SDK the JobyCorp apps use in place of `openai_ex`. It is consumed as a **git
dependency on `main`**, not from Hex, so pushing `main` there is a release:

```elixir
{:airo_client, git: "git@github.com:JobyCorp/airo_client.git", branch: "main"}
```

- `AiroClient.chat/2`, `chat_stream/2`, `embeddings/2`, `rerank/2`,
  `classify/2`, `speech/2`, `transcribe/3`, `models/1`, `model_catalog/1`,
  `voices/1` — one function per gateway capability, on `Req`.
- `AiroClient.Realtime` relays a browser WebSocket to Airo's `/v1/realtime`
  over `Mint.WebSocket`. The consumer terminates the browser leg itself; the
  browser never reaches Airo.
- Config is the gateway **host** plus a client key (`base_url` without `/v1`,
  `api_key`, `receive_timeout`), overridable per call. `model` may be an alias
  or a concrete deployment id; Airo resolves both.

Four apps depend on it today: incogito, orchester, mem_pal and media_assist.

## Docs

- [`docs/design/DESIGN.md`](./docs/design/DESIGN.md) — architecture reference
- [`docs/sprints/`](./docs/sprints/) — how the project is built, and what shipped when
- [`DEPLOY.md`](./DEPLOY.md) — releases and deployment
- [`airo_client`](https://github.com/JobyCorp/airo_client) — Elixir client SDK
- [`airo_agent`](../airo_agent) — the host-side control plane for GPU serving hosts

## License

MIT — see [LICENSE](./LICENSE).
