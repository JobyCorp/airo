# S1 — Transport & adapter behaviour

**Status:** [x] done  
**Branch:** `sprint/01-transport-adapter-behaviour`  

## Scope

- `Airo.Adapter` behaviour (`chat/stream/embed/rerank/speech/transcribe`)
- Own Req/Finch wrapper; one Finch named pool per `Provider` (DESIGN §13)
- `Airo.Registry` (adapter type → module)
- First OpenAI-compatible adapter: **chat, non-streaming**
- **DoD extra:** adapter unit-tested against a stubbed Req plug
