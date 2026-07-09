# S8 — Realtime proxy

**Status:** [x] done  
**Branch:** `sprint/08-realtime-proxy`  
**Design:** [DESIGN-realtime-and-client.md](../design/DESIGN-realtime-and-client.md) §4

## Scope

§4.
- `/v1/realtime` WebSocket (Bandit `WebSock` in, `Mint.WebSocket` out), Bearer auth
- Connect-time resolution + health routing; internal/external provider brokering
- Session-grained `UsageRecord`; `x-gateway-*` on the upgrade; transparent pass-through
- **DoD extra:** an app server relays browser STT through Airo to Speaches end-to-end
