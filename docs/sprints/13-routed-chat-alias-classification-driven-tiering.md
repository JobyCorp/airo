# S13 — Routed `chat` alias (classification-driven tiering)

**Status:** [x] done  
**Branch:** `sprint/13-routed-chat-alias-classification-driven-tiering`  
**Design:** [DESIGN-chat-routing.md](../design/DESIGN-chat-routing.md)

## Scope

Depends on S4 (routing),
S5 (Infinity classify adapter), S11 (trace/logs) — all merged.
A `chat` alias that classifies the prompt and routes to a model *tier* by
computing `route.class`; reuses candidate/health/failover wholesale. Ships in
**shadow mode** (logs its decision without acting) to calibrate before enforcing.
- `aliases.router` (`:none|:classify`) + `aliases.router_config` map; non-breaking
  (existing aliases default `:none`) — migration + changeset (DESIGN §8)
- `Airo.Routing.Classifier`: prompt → `route.class` via the configured `:classify`
  alias (Infinity deberta zeroshot), ordered labels + thresholds, **fail-open** on
  error/timeout (`timeout_ms` budget)
- One hook in `Gateway.alias_target/3`: set `route.class` in `enforce`, log-only
  in `shadow`; skipped when the caller pinned `route.class`/`route.binding` (DESIGN §9)
- `chat` + `prompt-class` config; structured `gateway.route.classified` log (S11 trace)
- **DoD extra:** T0 spike pins the Infinity `/classify` zero-shot contract; enforce
  filters to the predicted class, shadow serves the priority head and logs; a
  `router: :none` alias is byte-for-byte unchanged (non-regression test)
