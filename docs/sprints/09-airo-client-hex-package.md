# S9 — `airo_client` package

**Status:** [x] done  
**Branch:** `sprint/09-airo-client-hex-package`  
**Design:** [DESIGN-realtime-and-client.md](../design/DESIGN-realtime-and-client.md) §6

## Scope

HTTP capabilities (chat/embed/rerank/speech/transcribe/models) + streaming-as-messages;
realtime relay-to-Airo; replace `openai_ex` in both apps.

## Outcome

Shipped as a **monolithic git package** (`JobyCorp/airo_client`). Hex publish
deferred; private consumers install via git.

- `AiroClient` — chat / embeddings / rerank / speech / transcribe / models /
  `chat_stream` (SSE → messages) + transparency trailer
- `AiroClient.Realtime` — app → Airo `/v1/realtime` relay (same package, not a
  separate hex app)
- incogito + orchester depend on
  `{:airo_client, git: "git@github.com:JobyCorp/airo_client.git", branch: "main"}`
- Per-provider transport / `openai_ex` removed from both apps; STT relays through
  Airo

_Complete: closed 2026-07-09 as git-only monolith. Hex publish left as a later
option if external consumers appear._
