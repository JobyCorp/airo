# Sprint 24 — Site settings (time zone) & health flap suppression

> **Status: complete (S24).** 564 tests (+9), lint clean.

> **Decisions taken:** route is `/admin/settings`; no time zone auto-updater;
> the lifecycle log mirror is suppressed (not downgraded). The health threshold
> is a *setting on that page*, not a module attribute — configuration belongs in
> the UI. The tz library changed from the requested `tzdata` for a hard
> dependency reason — see below.

Two independent pieces. Companion to
[DESIGN-logging-traceability.md](../design/DESIGN-logging-traceability.md)
(S14, the operational log) and
[DESIGN-routing-settings.md](../design/DESIGN-routing-settings.md) (S16, whose
singleton-settings pattern part A copies).

> **Goal (one sentence):** give the admin a settings page whose first setting is
> the time zone every timestamp is rendered in, and stop the health prober
> reporting outages that never happened.

> **Why now.** Every timestamp in the admin is raw UTC with no label, read by
> someone in PDT — a seven-hour lie on every page. And `/admin/logs` is 100%
> health noise: **every** one of the 100 log events in the last 24h is a health
> transition, most of them fictional, which is what makes a real recurring
> failure on sparky invisible.

---

# Part A — Site settings and the time zone

## What's there now

Nothing. `grep settings lib/airo_web/router.ex` returns zero. Timestamps are
rendered by four private `format_at/1` clones across `logs_live`, `trace_live`,
`usage_live` and `agent_live` — twelve call sites — each doing:

```elixir
Calendar.strftime(naive_datetime, "%b %d  %H:%M:%S")
```

The values are `NaiveDateTime` in UTC (Postgres `timestamp`, `inserted_at`), so
this prints UTC and labels it as nothing at all. There is no time zone database
in the project: `tzdata` is not a dependency, and without one
`DateTime.shift_zone/2` cannot work.

## Design

**`Airo.Config.SiteSetting`** — a singleton row, exactly the shape S16 gave
`RoutingSetting`: one row, read through a context function, edited on one page.
That precedent already exists and is understood, so this adds a pattern nobody
has to learn.

First field: `time_zone`, default `"America/Los_Angeles"`.

**`{:tz, "~> 0.28"}`, not `tzdata`.** The brief said tzdata and I tried it
first: it depends on hackney, which pins `idna ~> 6.1`, while this project is on
**idna 7.1 via Mint** — the transport every gateway request runs through.
`mix deps.get` refuses the combination outright. Downgrading the HTTP stack of an
API gateway to add a clock feature is not a trade worth making, so this uses
`tz`, which implements the same `Calendar.TimeZoneDatabase` behaviour with no
HTTP dependency. It also has no background updater to disable — its
periodic-update module is opt-in and we don't start it — which satisfies the
autoupdate decision for free.

**One formatter, not four.** The four private `format_at/1` clones collapse into
a helper that takes the naive-UTC value, converts, and labels:

```elixir
naive
|> DateTime.from_naive!("Etc/UTC")
|> DateTime.shift_zone!(SiteSetting.time_zone())
```

**Route is `/admin/settings`**, consistent with the nine sibling pages and the
existing nav. (The brief said `/settings`; every other admin page is under
`/admin/*`, so this avoids the only top-level exception.)

## Deliverables (A)

1. `site_settings` table + `Airo.Config.SiteSetting` singleton, seeded with the
   default zone.
2. `tz` dependency + `:time_zone_database` config; no background updater.
3. Settings LiveView with a time zone select **and Part B's failure
   threshold**, plus a nav entry. The threshold is a knob an operator tunes
   against their own network, so it belongs on this page rather than in a
   module attribute.
4. One shared formatter; the four `format_at/1` clones deleted.
5. Tests: default when unset, a set zone changes rendering, DST correctness
   across a boundary (the reason a real tz database is needed rather than a
   fixed offset).

---

# Part B — The health flapping

## It is not the models

`/admin/logs` carries 100 events in 24 hours and **every one is a health
transition** (57 info, 43 warning). There are **three** producers, not one, and
they need different fixes. Grouped by `source`, with how long each `down`
survives before something reverses it:

| source | `down` events | avg seconds until reversed |
|---|---|---|
| **dispatch** | 21 | **4** |
| probe | 17 | 54 |
| agent | 24 | 150 |

A `down` that is undone in four seconds was never an outage.

### Cause 1 — one slow request marks a deployment down (`dispatch`, worst)

`Airo.Gateway.mark_health/2` records the outcome of every real request, on the
reasoning that "a real dispatch is a stronger signal than the periodic prober":

```elixir
{:transport_error, reason} ->
  Health.mark_deployment(deployment, provider, :down,
    source: :dispatch, reason: reason_code(reason))
```

That lumps **timeouts in with refusals**. A refused or reset connection is
evidence about the host; a request that ran past its receive timeout is not —
and this gateway is *known* to have generations that do exactly that (the
chat/stream receive timeout was raised to 300s precisely because big-context and
multi-step calls were exceeding it).

The signature on forge, agent-managed and therefore skipped by the prober:

```
21:15:40  Down  dispatch  transport_timeout
21:15:44  Up    agent                        ← 4 seconds later
```

`dispatch` wrote **21 downs and exactly 1 up** in 24h. It is almost a
write-only path to `:down`: recovery nearly always arrives from an agent push or
a probe, seconds later. This is the single largest producer of fiction and I
missed it in the first pass of this document — the `source` column is what gives
it away.

### Cause 2 — a single probe failure is treated as an outage

`gpt-5.6-sol` (OpenAI Codex, the cloud model — the case that shows on dev):

```
08:04:53  down  transport_timeout
08:05:26  up
08:12:13  down  transport_timeout
08:12:46  up
```

Every "outage" is **33 seconds**, fourteen times a day. The prober runs
`interval_ms: 30_000` with `probe_timeout_ms: 5_000`, and
`Health.mark_deployment/4` transitions on the *first* differing result:

```elixir
if previous != status, do: record_event(...)
```

One probe slower than five seconds against an internet endpoint marks it down;
the next probe thirty seconds later marks it up. There is no consecutive-failure
threshold anywhere in `Airo.Health`.

### Cause 3 — `unknown` means two different things

`deepseek-ai/DeepSeek-V4-Flash-0731:fp8` on sparky:

```
14:29:20  unknown  loading
14:36:00  down     transport_econnrefused
14:36:01  unknown  loading
14:36:43  up
14:59:53  down     tp_cluster_incomplete
15:00:29  unknown  loading
15:07:39  up
```

`loading` is a **known** state — the operator or the agent asked for a reload
and the slot is coming up. It's recorded as `:unknown`, the same value that
means "stale, we have not heard anything for 90 seconds". Each reload therefore
writes two to four transitions into the operational log.

Buried in that is the actual signal: `tp_cluster_incomplete`, the two-node
sparky/sparky2 TP cluster losing a member and the model genuinely going down.
**That is a real recurring failure and it is currently indistinguishable from
the noise around it.** Part B is what makes it visible; diagnosing it is not in
this sprint.

## Design

One idea covers causes 1 and 2: **a single failure is not an outage, whoever
observed it.** The threshold belongs in `Health.mark_deployment/4`, not in the
prober, so it applies to probe and dispatch alike.

**1. A timeout is not a host-health signal.** In `Gateway.mark_health/2`, split
`{:transport_error, reason}` by reason: a refusal or reset (`econnrefused`,
`closed`, `nxdomain`) is evidence about the host and still marks down; a
**timeout does not mark health at all**. The request still fails and still fails
over — this only stops one slow generation from labelling a working model dead.

**2. Hysteresis on the way down, none on the way up.** Require
`down_after_failures` consecutive failing observations (default 3, configurable)
before the effective status becomes `:down`. One success restores `:up`
immediately, so a real recovery is never delayed.

Safe because health is explicitly a *preference* signal, not an admission gate —
`Airo.Health.Prober`'s own moduledoc says "a probe failure never removes a
deployment" — and `Airo.Gateway` already fails over per request. The cost is
that a genuine outage is declared ~95s in rather than ~35s, against a gateway
already routing around it request-by-request.

**3. Stop mirroring lifecycle states into the operational log.** `health_events`
is incident history and keeps everything. `log_events` is what an operator
reads, and a reload is not an incident. Transitions whose reason is a known
lifecycle state (`loading`) stop being mirrored by `Health.record_event/1`.

**Suppressed, not downgraded.** Only the *mirror* into `log_events` goes;
`health_events` keeps the full sequence, so no history is lost.

**Expected outcome, against today's 24h:** the 21 dispatch downs and the 17
probe downs both go to near zero, the 18 `unknown (loading)` stop being
mirrored, and what remains is `tp_cluster_incomplete` and `econnrefused` — the
events that mean something. Roughly 100 events becomes single digits.

## Deliverables (B)

1. Timeouts no longer mark health in `Gateway.mark_health/2`; refusals still do.
2. Consecutive-failure threshold in `Health.mark_deployment/4` — applying to
   every source — with the counter in the existing ETS runtime state.
3. Lifecycle-state transitions no longer mirrored into `log_events`.
4. Tests: a dispatch timeout writes no health event; a refusal counts toward the
   threshold; N-1 failures don't transition and the Nth does; one success resets
   the counter and restores `:up`; a `loading` transition writes a
   `health_event` but no `log_event`.
5. Re-measure on prod after deploy and report the actual event count against the
   100/24h baseline above.

## Non-goals

- Diagnosing *why* sparky's TP cluster keeps losing a node. This sprint makes it
  legible; fixing it needs the agent side and its own sprint.
- Per-provider probe intervals or timeouts. The threshold is the general fix;
  a 5s timeout to a cloud endpoint may still deserve its own setting later.
- Alerting. Nothing here notifies anyone.

## Risks

- **A genuine outage is noticed ~60s later.** Mitigated by health being a
  preference signal with per-request failover already in place.
- **Suppressing lifecycle mirrors could hide a slot that never finishes
  loading.** A slot stuck in `loading` stops being routable via the staleness
  rule, but nothing would say so in the log. Worth a follow-up: an event when a
  slot has been `loading` beyond a threshold.
- **tzdata's updater** — see the decision above.

## Acceptance

- `/settings` renders, the zone persists, and every admin timestamp shows in it
  with a zone label; DST verified across a boundary by test.
- The three flapping deployments produce **zero** `down`/`up` pairs shorter than
  the threshold window over a full day on prod, verified by query after deploy.
- Suite green, `mix joby_kit.lint` clean.
