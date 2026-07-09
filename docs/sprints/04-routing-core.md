# S4 — Routing core

**Status:** [x] done  
**Branch:** `sprint/04-routing-core`  

## Scope

- Multi-candidate selection: `weighted | priority | round-robin`
- Health prober → ETS/`:persistent_term` (~90s staleness signal, not hard gate)
- Failover/retries along the fallback chain
- Strict pin via `route.binding` → serve or `selected_binding_unavailable`
- **DoD extra:** routing + failover unit-tested with a downed stub
