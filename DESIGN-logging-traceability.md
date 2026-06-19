# Airo — Logging & traceability (S14)

Spec for **S14 — Logging & traceability**. Companion to [DESIGN.md](./DESIGN.md)
§10 (Observability). Builds on S11 (request trace ids + structured gateway logs)
and S13 (classifier predictions). This is the implementation hand-off: it names
exact files/functions and fixes the decisions.

> **Goal (one sentence):** give the operator a persisted, filterable **operational
> event log** at `/admin/logs` plus **cross-surface traceability** by `trace_id`,
> so routing can be calibrated and requests debugged entirely in-app — while
> `/admin/usage` stays consumption-focused (tokens / cost / latency).

---

## 1. Why this is needed

Today operational signal is scattered and partly invisible:

- **Classifier predictions** (`gateway.route.classified`) and **gateway attempts**
  (`gateway.attempt.*`, `gateway.stream_attempt.*`) are **Logger-only** — they go to
  stdout and are not queryable in-app. In a homelab release that means tailing
  journald/`docker logs` to calibrate routing. Too clunky for the shadow→enforce
  loop S13 ships.
- **Health transitions** *are* persisted (`health_events`, `Health.list_events/1`)
  and shown on three pages, but there's no single operational timeline.
- `/admin/usage` has become the de-facto "logs" surface, but it's a *consumption*
  view (one row per served request: tokens, cost, latency, outcome). Prediction and
  health signal don't belong there.

So: add a real event-log store + viewer, and make `trace_id` stitch a single
request across usage ↔ logs ↔ health. Keep `/usage` exactly as it is.

## 2. Fixed decisions (do not re-litigate)

- **Persisted, not ephemeral.** A `log_events` table (survives restarts) — an
  in-memory ring is a non-goal; calibration needs history.
- **Explicit writes, off the hot path — NOT a global Logger handler.** A Logger
  handler that writes to the DB sits *inside* the logging pipeline (every Ecto
  query logs, so a DB write there risks recursion and adds latency to the hot
  path). Instead, call `Airo.Logs.record/1` at the few emission points we control,
  and have it hand the write to an async writer so the caller never blocks.
- **Keep the stdout Logger lines.** `log_events` is *additive*; existing
  `Logger.info(...)` calls stay (operators may also ship stdout to a sink).
- **`/usage` is untouched.** Consumption stays in `usage_records`; this sprint adds
  no columns there and changes no usage behavior (non-regression).
- **v1 captures predictions + health only.** Gateway attempt/failover events
  largely duplicate what `usage_records` already records (served deployment,
  `fallback_used`, `error_code`, latency, outcome); defer them (§8).

## 3. Data model

New table `log_events` (`Airo.Logs.LogEvent`, `lib/airo/logs/log_event.ex`):

| column | type | notes |
|--------|------|-------|
| `kind` | `Ecto.Enum [:route_prediction, :health]` | extensible (`:gateway_attempt`, … later) |
| `level` | `Ecto.Enum [:info, :warning, :error]` | for filtering/coloring |
| `trace_id` | `string`, null | the S11 gateway trace id; the correlation key |
| `summary` | `string` | the human one-liner (mirrors the Logger message) |
| `data` | `:map` (jsonb), default `%{}` | kind-specific payload (see below) |
| `alias_name` | `string`, null | filter ref (e.g. `chat`) |
| `provider_id` | FK → providers, `nilify_all` | filter ref |
| `deployment_id` | FK → deployments, `nilify_all` | filter ref |
| `inserted_at` | timestamp | no `updated_at` (append-only) |

Indexes: `inserted_at`, `kind`, `trace_id`, `level`. Mirrors `health_events`
conventions (append-only, FK `nilify_all`).

`data` payloads:
- `:route_prediction` — `%{predicted_class, scores, mode, applied, latency_ms}`
- `:health` — `%{status, source, reason, latency_ms}`

## 4. Context — `Airo.Logs` (`lib/airo/logs.ex`)

- `record(attrs) :: :ok` — **non-blocking.** Casts the write to the async writer
  (§5); returns immediately. Never raises into the caller (fire-and-forget).
- `list(filters, limit) :: [LogEvent.t()]` — newest-first, preloaded
  provider/deployment, filtered by kind/level/range/trace/alias/predicted_class.
  Mirror `Airo.Usage.list_usage_records/2`.
- `for_trace(trace_id) :: [LogEvent.t()]` — all events for one trace, oldest-first
  (timeline order). Feeds the trace drilldown (§6).
- Filter option helpers (`kind_options/0`, `level_options/0`) for the UI selects.

## 5. Capture — off the hot path

A tiny async writer so the request path never waits on a log insert:

- **`Airo.Logs.Writer`** — reuse the existing `Task.Supervisor`
  (`Airo.Usage.TaskSupervisor`, already supervised) the way `Airo.Usage` records
  off-path: `Task.Supervisor.start_child(sup, fn -> Repo.insert(...) end)`, wrapped
  so a failed insert is swallowed (logging must never break a request). If volume
  warrants batching later, swap in a GenServer buffer — `Airo.Logs.record/1` stays
  the stable surface.

Emission points:
1. **Route predictions** — in `Airo.Gateway.log_classified/5`
   (`lib/airo/gateway.ex`), alongside the existing `Logger.info`, add
   `Logs.record(%{kind: :route_prediction, level: ..., trace_id: trace_id,
   alias_name: alias_.name, summary: <the message>, data: %{predicted_class, scores,
   mode, applied, latency_ms}})`. Enforce runs in the request process, so this MUST
   be async (it is, via the writer). Shadow already runs detached.
2. **Health transitions** — in `Airo.Health.record_event/1` (`lib/airo/health.ex`),
   after persisting the `health_event`, also `Logs.record(%{kind: :health, ...})`.
   This is a dual-write: it leaves the `health_events` table and its three existing
   readers (deployment detail, dashboard, model detail) **untouched**, and gives the
   logs timeline a unified feed. `level`: `:down` → `:warning`, else `:info`.

## 6. Traceability

- **`/admin/logs`** (`AiroWeb.Admin.LogsLive`, modeled on `UsageLive`): a stat strip
  (counts by level/kind) + a filter form (kind, level, time range, alias,
  predicted_class, trace) + a `<.table>` timeline. Nav entry **"Logs"**
  (`active_nav="logs"`). Each row's `trace_id` is clickable.
- **Cross-links.** From `/usage`, the existing trace funnel also links to
  `/admin/logs?trace=<id>`; from `/admin/logs`, a trace links back to
  `/usage?trace=<id>`. Same `trace_id`, two lenses (consumption vs operations).
- **Trace drilldown** — given a `trace_id`, stitch **one timeline**: the
  `usage_records` row(s) for that trace + every `log_events` row
  (`Logs.for_trace/1`), ordered by time. Surfaced either as a dedicated
  `/admin/logs/:trace_id` view or an expandable panel. This is the "what happened to
  *this* request" view: predicted tier → served deployment → fallbacks → health at
  the time → final outcome/cost.

## 7. Tasks

- **T1 — store + context.** Migration `create_log_events`; `Airo.Logs.LogEvent`
  schema + changeset; `Airo.Logs` (`record/1` async via writer, `list/2`,
  `for_trace/1`, option helpers). Extend the Oban housekeeping that prunes
  `usage_records` to prune `log_events` on the same retention. Tests: changeset,
  `list/2` filters, `for_trace/1` ordering, prune.
- **T2 — capture.** Wire `Logs.record/1` into `Gateway.log_classified/5` (predictions)
  and `Health.record_event/1` (health dual-write). Tests: a routed request writes a
  `:route_prediction` event with the right `data`/`trace_id` (stubbed Req); a health
  transition writes a `:health` event; **capture never adds latency** (async) and a
  writer failure can't fail the request (non-regression).
- **T3 — `/admin/logs` viewer.** Route + nav entry; `LogsLive` (stat strip +
  filters + table) using JobyKit wrappers (`<.table>`, `<.input>`, `<.card>`,
  `CompositeComponents.page_header`); cross-links to/from `/usage`. `mix
  joby_kit.lint` green. LiveView test: events render, filters narrow, trace link
  navigates.
- **T4 — trace drilldown.** `for_trace/1`-backed unified timeline (usage + logs) for
  a `trace_id`. Test: a seeded request's prediction + usage row + health appear in
  order for its trace.
- **T5 — docs.** DESIGN.md §10: add a "Logs & traceability" note pointing here.
  SPRINTS.md: tick S14 + status-log line on merge.

## 8. Non-goals / deferred

- **Generic Logger-handler capture of *all* logs** (every `Logger` line → DB) — a
  bigger, riskier mechanism; revisit if we want raw debug capture in-app.
- **Gateway attempt/failover events** in `log_events` — overlap `usage_records`;
  add the `:gateway_attempt` kind later if per-attempt detail proves necessary.
- **Log export / live streaming / retention policy UI** — v2.
- **Predicted class on `usage_records`** — still a non-goal (it lives in
  `log_events` now, correlated by `trace_id`).

## 9. Definition of Done

Global DoD (`mix precommit` green; new behavior tested against stubs, not live;
`DESIGN.md`/`SPRINTS.md` updated; `joby_kit.lint` green; branch merged) **plus**:
- Route predictions **and** health transitions are visible and filterable in
  `/admin/logs`, persisted across restarts.
- A `trace_id` correlates a single request across `/usage` and `/admin/logs`, with
  a unified trace drilldown.
- Capture is **off the hot path** (adds no request latency) and **cannot recurse**
  or fail a request.
- `/admin/usage` is byte-for-byte unchanged (non-regression).
