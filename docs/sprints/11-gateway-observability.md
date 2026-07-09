# S11 — Gateway observability

**Status:** [x] done  
**Branch:** `sprint/11-gateway-observability`  

## Scope

Post-cutover production observability for Airo as the single AI model path for
incogito and orchester.
- Trace identity: every HTTP request, SSE stream, and realtime session carries a
  gateway trace id in response metadata, logs, and persisted usage/audit records
- Structured gateway logs for request start/finish, resolution, attempt failures,
  fallback, stream partial errors, and realtime close events
- Failed-request accounting: persist traceable rows for auth, routing,
  unsupported capability, upstream HTTP errors, transport errors, stream partial
  errors, and realtime connection failures
- Usage admin upgrade: filters by client/capability/model/outcome/time range,
  trace-id copy/link affordance, and summary cards for count, error rate,
  p50/p95 latency, fallback count, and cost
- Provider/model health history sufficient to explain incidents and feed the
  future Model Shelf
- **DoD extra:** a failed request and a successful streamed request can both be
  correlated across response headers/SSE metadata, logs, and `UsageRecord`;
  realtime sessions carry one trace id from connect through close
- _Complete: implemented on `sprint/11-gateway-observability`; `mix
  precommit` and `mix joby_kit.lint` green._
