# S14 — Logging & traceability

**Status:** [x] done  
**Branch:** `sprint/14-logging-traceability`  
**Design:** [DESIGN-logging-traceability.md](../design/DESIGN-logging-traceability.md)

## Scope

Builds on
S11 (trace ids/logs) and S13 (classifier predictions).
A persisted operational event log at `/admin/logs` + cross-surface traceability by
`trace_id`, so calibration and request debugging happen in-app — `/usage` stays
consumption-focused (tokens/cost/latency).
- `log_events` table (`kind`/`level`/`trace_id`/`summary`/`data` jsonb + alias/provider/
  deployment refs); `Airo.Logs` context (`record/1` async, `list/2`, `for_trace/1`),
  pruned by the existing Oban housekeeping
- Capture **off the hot path** (async writer reusing the Task.Supervisor, **not** a
  Logger handler): route predictions (`gateway.route.classified`) + health transitions
  (dual-write from `Health.record_event`); existing stdout Logger lines stay
- `/admin/logs` LiveView (stat strip + filters: kind/level/range/alias/predicted_class/
  trace) modeled on `/usage`; "Logs" nav entry; cross-links to/from `/usage`
- **Traceability:** a trace drilldown stitching the `/usage` row + all `log_events` for a
  `trace_id` into one timeline
- **DoD:** predictions + health visible/filterable in `/admin/logs`; a `trace_id`
  correlates a request across `/usage` and logs; capture adds no request latency and
  can't recurse; `/usage` byte-for-byte unchanged
