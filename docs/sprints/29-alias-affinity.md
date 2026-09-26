# Sprint 29 — Session affinity for aliases (`route.affinity` + an `affinity` strategy)

> **Status: built on branch `feat/alias-affinity` on 2026-09-26; not merged or
> deployed.** 691 tests (+19 over S28), `mix precommit` green,
> `joby_kit.lint` 16 (unchanged). One migration (`usage_records.affinity`).

> **Goal (one sentence):** send consecutive rounds of one helm session to the
> same card, so they hit that card's prefix cache.

> **Why.** `agent-fast` round-robins every request. In helm's delegation run,
> rounds changed card on 35 of 58 boundaries, only 35–71% of prompt tokens
> were cached, and sessions spent 14–63% of their time waiting for the first
> token.

## What shipped

- **Request.** `route.affinity` — optional string, at most 128 bytes. Any
  other value is a 400 with code `invalid_affinity`. An empty string is no
  key. `route` is already a gateway-only key (`Airo.Gateway.Params`), so it
  is never forwarded upstream; a test asserts it.
- **Strategy.** `:affinity` on `Airo.Config.Alias` (string column, no
  migration), selectable on `/admin/aliases` with a hint.
  `Airo.Routing.Affinity` does the work, after the strategy order and the
  health re-sort:
  - New key → the candidate with the fewest in-flight requests
    (`InFlight.count/1`); ties go to the fewest live keys on this alias, then
    the round-robin position, so sessions started at idle still spread.
  - Known key → its deployment first; the rest stay in round-robin order as
    the failover order.
  - Its deployment disabled, filtered out, or `:down` → reassigned to the
    least busy live candidate.
  - Idle for 30 min → dropped; the next request assigns again. Expired keys
    are swept whenever a new key is assigned.
  - Two first requests of one session racing: `:ets.insert_new` makes the
    second follow the first.
- **Unchanged.** No key → exactly round-robin. `route.binding` wins; the key
  is neither read nor written. A fallback alias with `:affinity` orders
  round-robin and never takes the key. Other strategies ignore the key.
- **Observability.** `x-gateway-affinity: assigned|hit|reassigned|none` on
  every gateway response (up front on streams, and in the `gateway.metadata`
  SSE event); the same value in `usage_records.affinity`, the
  `gateway.request.completed` log line, and the `/admin/usage` detail. Error
  rows carry nil. The key itself is not logged.
- **State.** Assignments live in the `:airo_routing` ETS table as
  `{{:affinity, alias_id, key}, deployment_id, last_seen_ms}`. A node restart
  forgets them.

## Acceptance still to do (live)

- Switch `agent-fast` to the `affinity` strategy on prod and have helm send
  `route.affinity` per session.
- helm measures with `mix helm.turn_shape --delegation`: at least 95% of
  consecutive rounds per session stay on one card, and the workers'
  cached-prompt share rises from 55% to at least 85%.

## Not in scope

Priority classes, KV transfer, and any change to other strategies or to
aliases that don't opt in.
