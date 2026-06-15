# Airo — Realtime & Client Design

> Extends [DESIGN.md](./DESIGN.md). This is the reference for two follow-on
> pieces after the HTTP gateway (S0–S6) and consumer migration: a **realtime
> WebSocket proxy** in Airo, and a shared **`airo_client` hex package** that both
> consumers use instead of `openai_ex`.

Status: **design**. Code follows it.

---

## 1. Scope

What's already true (DESIGN.md, S0–S6, plus the concrete-model change):

- Airo is a standalone OpenAI-compatible HTTP gateway: `/v1/chat/completions`
  (+SSE), `/v1/embeddings`, `/v1/rerank`, `/v1/audio/{speech,transcriptions}`,
  `/v1/models`, with routing/failover, health, usage, and a config UI.
- `model` resolves as **either an alias or a concrete deployment id**.
- incogito is validated against Airo for chat / embeddings / speech (TTS) via
  concrete model ids; STT is still a direct browser→Speaches realtime WebSocket.

What this doc adds:

1. **Realtime through Airo** — so STT (and future realtime voice) stops being a
   direct browser→provider connection and runs through the gateway like
   everything else.
2. **`airo_client`** — the Elixir client both apps depend on, replacing
   `openai_ex`, that owns *everything app↔Airo* and nothing browser-facing.

Out of scope: distributed-Erlang/RPC transport (see §3), cross-provider realtime
*normalization* (the proxy is a transparent pass-through, see §4).

---

## 2. Topology & invariants

```
browser ⇄ [app PUBLIC ssl: WS/WebRTC] ⇄ incogito / orchester server
                                              ⇅  server→server, private (HTTP + WS)
                                            Airo  (private; holds provider creds + network path)
                                              ⇅  HTTP / WS
        internal providers (Speaches / vLLM / Infinity / Ollama …)  OR  external (OpenAI realtime / cloud …)
```

Hard invariants (these drive every decision below):

- **The browser only ever connects to the app's own public SSL URL.** Never
  Airo, never a provider.
- **The app only ever talks to Airo.** Never a provider directly; it holds no
  provider credentials and needs no provider network path.
- **Airo is the only thing that touches providers** — it holds their
  credentials and has the network route (LAN for internal, internet for
  external). Therefore Airo is *in* the realtime data path: it **proxies**.
- **Airo has no public ingress.** It is reached only server-to-server from the
  consumer apps on the private network.

A consequence worth stating: **"internal vs external provider" is entirely
Airo's concern** — invisible to the apps and to `airo_client`. A realtime call
looks identical whether Airo relays to a LAN Speaches or a cloud realtime API.

---

## 3. Transport decisions

**HTTP is the wire. SSE for streaming. WebSocket for realtime.** No exceptions in
the request path.

**Distributed-Erlang / BEAM RPC is ruled out** (for now), despite the apps and
Airo all being BEAM nodes on a private network. Rationale:

- *Latency is a non-argument* for this workload — the model dominates by orders
  of magnitude; an HTTP hop on a LAN is noise.
- *Lifecycle coupling* — a dist cluster ties node lifecycles together (an Airo
  restart drops every live session); HTTP degrades to a reconnect.
- *The dist channel is a footgun for bulk payloads* — a single connection per
  node pair with head-of-line blocking; audio frames or large
  completions/embeddings can stall heartbeats → node disconnects. Realtime audio
  over dist is a hard no.
- *It would re-introduce coupling Airo exists to avoid* and forfeit the
  OpenAI-compatible universality that made the migration "point a base_url."

The door stays open *only* behind the client's transport abstraction (§6): a
future BEAM transport for the request/control path could be added without
touching the apps. It is not built, and never carries audio.

**Streaming as messages.** SSE is an implementation detail of the wire;
`airo_client` consumes it on the *consumer's* node and surfaces `{:delta, chunk}`
messages to the caller's process. The app gets BEAM message-passing ergonomics
(LiveView `handle_info`, Sink/Riser) without distributed Erlang.

---

## 4. Realtime architecture (Airo proxies)

Airo gains a **realtime WebSocket reverse proxy**. The consumer's *server* (not
the browser) connects to it; Airo opens an outbound WebSocket to the resolved
provider and pumps frames both ways.

```
app server  ──WS──▶  Airo /v1/realtime  ──WS──▶  provider realtime (internal | external)
            ◀──WS──             (frame pump)     ◀──WS──
```

### 4.1 Endpoint & auth

- `GET /v1/realtime?model=<alias|id>&intent=transcription` (WebSocket upgrade),
  mirroring the OpenAI/Speaches realtime convention. Other intents (e.g. voice)
  later.
- Auth: **`Authorization: Bearer <client-key>`** on the upgrade request. Because
  the consumer is a *server*, it can set headers — so **no browser-ticket
  gymnastics**; reuse `ClientKeyAuth`.
- `x-gateway-*` transparency headers ride on the `101 Switching Protocols`
  response (served provider/model).

### 4.2 Resolution & routing

- Resolve `model` (alias or concrete id, per the existing Gateway) to a
  **realtime-capable** deployment for the intent's capability (e.g.
  `transcription`). The deployment/provider carries the upstream realtime URL
  shape and credentials.
- **Routing is connect-time only.** Pick a healthy candidate at session open;
  there is **no mid-session failover** (re-establishing a live audio session
  loses context). "Failover" here means "choose well at connect."

### 4.3 Internal vs external (Airo's job alone)

- **Internal** (Speaches on the LAN): Airo opens `wss://{base_url}/v1/realtime?…`
  with the provider's key. Standard.
- **External** (e.g. OpenAI realtime): Airo holds the cloud credential and, where
  the provider uses ephemeral session keys, **mints them on the outbound side**.
  The app never sees provider URLs or tokens.

### 4.4 Transport implementation

- **Inbound**: a `WebSock` handler (Bandit) per session, upgraded via
  `WebSockAdapter`.
- **Outbound**: `Mint.WebSocket` (same Mint stack Finch/Req sit on). One
  dedicated socket pair per session — realtime connections are **not pooled**
  like HTTP.
- The session process owns both sockets and relays frames, propagating close and
  error in both directions, with keepalive ping/pong and frame-size limits.

### 4.5 Usage

- **Session-grained** `UsageRecord` (not per-token): capability, deployment,
  client_key, outcome, session duration (`latency_ms`), and optionally
  audio-bytes / transcript-event counts. Written on session close (off-path).

### 4.6 Transparent pass-through, not normalization

The proxy forwards realtime frames; it does **not** translate between realtime
dialects. Cross-provider realtime normalization is a much larger effort and is
explicitly out of scope. The gateway value here is: one private endpoint,
client-key auth, model resolution, connect-time health routing, credential
custody, and usage — not protocol translation.

---

## 5. The boundary: `airo_client` == the Airo boundary

The "app only talks to Airo" invariant collapses the package-scope question:
**the package owns everything app↔Airo, and nothing browser-facing.**

| Layer | Owns |
|---|---|
| **App** (incogito / orchester) | The **browser leg** — terminate WS/WebRTC, mic capture, rendering (Sink/Riser), conversations/assets, the app's UX. Per-app; different UIs; stays per app. App telemetry (Runlog) and config (`Settings`/`CapabilityAssignment`) stay app-side. |
| **`airo_client`** | The **Airo leg** — HTTP capabilities + streaming-as-messages, **and** the realtime **relay to Airo** (open a WS to Airo, pump audio frames up, surface transcript events as messages). Pure Elixir, server-side, ends at Airo. |
| **Airo** | The **provider leg** — the realtime WS proxy and brokering internal/external providers (creds, network, which provider). |

Consequences:

- **No shared browser JS / LiveView layer.** Each app keeps its own browser
  realtime code. `airo_client` is pure server-side Elixir.
- The app feeds `airo_client` browser audio and renders what comes back; it never
  knows whether the bytes reached a LAN Speaches or a cloud API.

---

## 6. `airo_client` package

"The Airo SDK for Elixir." Replaces `openai_ex` in both apps.

### 6.1 Config

```elixir
config :airo_client,
  base_url: "http://airo.internal:4000",   # private; server-to-server
  api_key:  System.get_env("AIRO_CLIENT_KEY"),
  receive_timeout: 120_000                  # generous default (slow deep models)
```

Per-call overrides for `base_url`/`api_key`/`receive_timeout`. Own thin Req/Finch
wrapper (consistent with Airo's own no-`openai_ex` stance).

### 6.2 Capabilities (request/response)

```elixir
AiroClient.chat(params, opts \\ [])          # {:ok, body} | {:error, reason}
AiroClient.embeddings(params, opts \\ [])
AiroClient.rerank(params, opts \\ [])
AiroClient.speech(params, opts \\ [])        # {:ok, {audio_binary, content_type}}
AiroClient.transcribe(file, params, opts)    # multipart upload (non-realtime path)
AiroClient.models(opts \\ [])                # aliases + concrete model ids
```

- `params["model"]` is an alias *or* a concrete deployment id (Airo resolves
  both).
- The **`route` extension** is passable (`route: %{class:, tools:, binding:,
  fallback:}`) for power cases.
- `x-gateway-*` transparency (served provider/model, `fallback_used`, latency) is
  surfaced to the caller (e.g. in response metadata / the stream's `:done`).
- Errors normalize to tagged tuples: `{:error, {:http, status, body}}`,
  `{:error, {:transport, reason}}`, etc. (Airo's OpenAI-shaped error envelope is
  passed through.)
- **No client-side retry of dispatch** — Airo already fails over internally;
  double-dispatch is wrong. The client only retries genuine connection failures
  to Airo itself.

### 6.3 Streaming (as messages)

```elixir
{:ok, ref} = AiroClient.chat_stream(params, into: self())
# caller receives:
#   {:airo, ref, {:delta, chunk}}     # normalized OpenAI delta (content / reasoning_content / tool_calls)
#   {:airo, ref, {:done, metadata}}   # x-gateway-* served/fallback/latency
#   {:airo, ref, {:error, reason}}
```

Message-passing is the default (LiveView `handle_info`, Sink/Riser). A `Stream`
form may be offered for non-LiveView callers. The SSE→messages bridge runs on the
consumer node, inside the package.

### 6.4 Realtime relay (to Airo)

```elixir
{:ok, session} = AiroClient.Realtime.connect(model: "whisper-…", intent: :transcription)
AiroClient.Realtime.send_audio(session, pcm16_frame)     # app pumps browser audio in
# caller receives:
#   {:airo_realtime, ref, {:transcript, text}}
#   {:airo_realtime, ref, {:event, raw_event}}
#   {:airo_realtime, ref, :closed}
#   {:airo_realtime, ref, {:error, reason}}
AiroClient.Realtime.close(session)
```

The package owns the **WS to Airo** only. The **app** owns the browser WS/WebRTC
and wires it to this relay: browser audio in → `send_audio`; transcript messages
out → the app's UI.

### 6.5 Packaging

Layered so apps take only what they need:

- **`airo_client`** — HTTP capabilities + streaming. (Both apps; ship first — it
  unblocks the migration cleanup immediately.)
- **`airo_client_realtime`** — the realtime relay. (Apps doing realtime; ship
  with the Airo realtime proxy.)

---

## 7. Consumer migration impact

For incogito and orchester:

- **Replace `openai_ex` with `airo_client`.** Chat/embeddings/rerank/speech go
  through Airo by alias or concrete model id (already validated for incogito).
- **Delete per-provider transport code** — `Rerank.Providers.Infinity` (and its
  `/v1`-strip), the Speaches TTS path, per-provider LLM/embeddings adapters. That
  knowledge now lives in Airo's adapters.
- **Keep** `Settings`/`CapabilityAssignment` (config, pointing at the one "airo"
  connection), Runlog (app telemetry), Sink/Riser and the agent loop (rendering /
  orchestration), and image-gen/search/news (app-specific, never Airo's).
- **STT**: move from browser→Speaches-direct to
  browser → app (WS/WebRTC) → `AiroClient.Realtime` → Airo → Speaches. The
  browser stops knowing any URL but the app's own.

---

## 8. Sequencing

- **S8 — Airo realtime proxy.** `/v1/realtime` WebSocket (Bandit `WebSock`
  inbound + `Mint.WebSocket` outbound), Bearer auth, connect-time resolution +
  health routing, internal/external brokering (incl. ephemeral-token minting for
  external), session usage records, transparency on the upgrade. Transparent
  pass-through.
- **S9 — `airo_client` (+ `_realtime`).** The Elixir client; replace `openai_ex`
  in both apps; collapse their per-provider transport code; move STT to the
  realtime relay.

(Order is flexible: `airo_client` core can land first against the existing HTTP
surface, independent of the realtime proxy.)

---

## 9. Non-goals / open questions

**Non-goals**
- BEAM/RPC transport in the request path (§3); audio never on dist.
- Cross-provider realtime *normalization* (§4.6) — transparent pass-through only.
- Shared browser JS / LiveView realtime layer (§5) — per-app.
- Mid-session realtime failover (§4.2) — connect-time routing only.

**Open questions**
- [ ] Exact realtime intents beyond `transcription` (full-duplex voice?), and
      whether the proxy needs per-intent session-config handling.
- [ ] Realtime usage granularity — session duration only, or audio-bytes /
      transcript-event counts too.
- [ ] Per-deployment/alias **timeout** config (the slow-deep-model lesson): a
      `receive_timeout_ms` in `default_params` so a deep tier can exceed Airo's
      flat 60s without loosening it globally. (Small Airo change; relevant once a
      consumer raises its own client timeout past 60s.)
- [ ] `airo_client` transparency surface — how much of `x-gateway-*` to expose,
      and whether to thread an `x-trace-id` (incogito's `trace_id`) through for
      end-to-end correlation in Airo's `UsageRecord`.
