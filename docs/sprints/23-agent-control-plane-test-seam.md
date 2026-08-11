# Sprint 23 — A test seam for the agent control plane

> **Status: complete (S23).** 555 tests (+10), lint clean.

Companion to [DESIGN-agent-management.md](../design/DESIGN-agent-management.md)
(S17, the control plane) and [DESIGN-slot-config.md](../design/DESIGN-slot-config.md)
(S20, the config modal).

> **Goal (one sentence):** make the online-only half of `/admin/agents/:id`
> reachable from a test, then cover it — today none of it has ever been
> rendered by the suite.

> **Why now.** On 2026-08-11 `/admin/agents/8` returned 500 for every online
> agent in production. 545 tests were green. The failing line renders only when
> a host is online, and no test has ever put a host in that state, so the suite
> could not have caught it — and won't catch the next one either.

---

## The root cause

Two locks, and both have to be picked before a single assertion is possible.

**Lock 1 — no seam to the control API.** `AiroWeb.Admin.AgentLive` calls
`Airo.Agents.Control` directly with no options:

```elixir
# lib/airo_web/live/admin/agent_live.ex:268
case Control.inventory(agent) do
```

`Control` itself is perfectly stubbable — `request/5` merges
`opts[:req_options]` into `Req.request/1`, and `control_test.exs` uses exactly
that with `plug: {Req.Test, __MODULE__}` across nine tests. But the stub has to
be threaded through the *caller*, and the LiveView passes nothing. Same for
`refresh_inventory/1` (:185), `unload/2` (:197) and `load/4` (:461).

S22 already hit this and wrote it down in its deferred list:

> *"`Control.inventory/2` takes no stub and the dev host is offline."*

**Lock 2 — nothing can make a host look online.** The whole surface is gated on
one predicate:

```elixir
defp online?(host_id), do: Presence.list("agent:#{host_id}") != %{}
```

`assign_inventory/1` doesn't even call the control API unless `online: true`.
No test tracks presence, so every test sees every host as offline and renders
the offline branch.

The two locks compound: picking only Lock 2 gets you an online page whose
inventory fetch makes a real HTTP call to a `control_url` that doesn't resolve,
so you land in the error branch instead of the one you wanted to test.

---

## What is actually uncovered

Everything below renders only when a host is online. None of it appears in any
test today.

| Surface | Line | Why it matters |
|---|---|---|
| Loadable-models table | 936–976 | **The 500.** Load / Configure per model |
| — its computed variant | 966 | `variant={if model.resident?, …}` — the bug |
| Inventory error branch | 271–276 | What an operator sees when a host is unreachable |
| Inventory empty state | 926 | Host reports no models |
| Refresh inventory | 918 | Re-scans the host's artifacts |
| Slot Configure / Unload | 884, 895 | Interrupts in-flight requests |
| Resync | 648 | Broadcasts to the agent channel |
| Config modal end-to-end | 1030+ | VRAM validation, hard block, submit → `load` |

The config modal is the sharpest of these: S21 gave it a **hard block** that
refuses an over-budget context because the documented failure is a
KV-cudaMalloc segfault on the host. That guard has never been exercised by a
test through the page.

---

## Why the bug got through, precisely

The variant is computed, not literal:

```elixir
variant={if model.resident?, do: "secondary", else: "primary"}
```

Three defences existed and each one had a legitimate blind spot:

1. **`mix compile --warnings-as-errors`** — Phoenix validates `attr` `values:`
   against *literals*. A value produced by an `if` is opaque at compile time.
2. **A static sweep of call sites** — this is how the rest of the 0.3 rename was
   done, and it worked for the other 32. `grep` cannot see inside the branch.
3. **The kit's own guard** — `Map.fetch!` raises on an unknown variant, which is
   correct and loud. It just only fires when the branch renders.

Rendering the page is the only defence that would have worked. That is the whole
sprint.

---

## Design

### 1. A default-options seam on `Control`

One line in `Airo.Agents.Control.request/5`: merge application-env
`req_options` *under* the caller's, so explicit opts still win and no call site
changes.

```elixir
|> Keyword.merge(default_req_options())
|> Keyword.merge(Keyword.get(opts, :req_options, []))
```

Dev and prod set nothing and behave exactly as now. Req's documented testing
pattern, no dependency, LiveView untouched — the seam belongs to the HTTP
client, not to the page.

**Opt-in per test, not global.** The first cut set the plug in
`config/test.exs` for the whole suite, and that broke five tests in
`live_launch_profile_test.exs`. Routing every call through `Req.Test` makes an
un-stubbed call *raise*; before, it failed like an unreachable host, and those
tests were asserting the degraded path — `Ingest.inventory_index/1` falls back
to identity-only when the control API can't be reached (S19). `stub_control/1`
therefore installs the plug for one test and removes it on exit, so every test
that didn't ask for a stub sees the refused connection it always saw.

**Rejected:** a behaviour + Mox (a new dep and an indirection layer for one
caller); threading `req_options` through the LiveView (test concerns in
production code).

### 2. A presence helper

`Req.Test` stubs are process-owned, and the fetch happens inside the LiveView
process during mount — before the test can hand it an allowance. So these tests
run **`async: false`** with a globally-set stub. That is a real cost and the
reason to keep them in their own module rather than widening
`agent_live_test.exs`, which stays `async: true`.

A helper in `test/support` covering both locks:

```elixir
mark_online(host_id)          # Presence.track on "agent:<host_id>"
stub_control(fn conn -> … end) # Req.Test stub for Airo.Agents.Control
```

### 3. Coverage

New `test/airo_web/live/agent_live_online_test.exs`, one test per row of the
table above, plus a named regression test for the 500 that asserts a **resident**
model renders its action button — the exact state that raised.

---

## Deliverables

1. `Control` default-`req_options` seam + `config/test.exs` wiring.
2. `mark_online/1` and `stub_control/1` test helpers.
3. `agent_live_online_test.exs` covering the eight surfaces above.
4. A line in `STATUS.md`.

## Non-goals

- Changing any runtime behaviour of the page. This sprint adds no features and
  fixes no bugs beyond the one already shipped in `f265bd2`.
- Testing `airo_agent` itself, or the real control API over the wire.
- Browser-level tests. These are LiveView render/interaction tests.
- Retro-fitting the same seam to other HTTP callers (`LocalModels`, the prober).
  Worth doing, separate sprint.

## Risks

- **Presence leaks between tests.** Tracking from the test pid ends when the pid
  dies, but a shared tracker means ordering surprises. Mitigation: untrack in
  `on_exit`, unique `host_id` per test.
- **`async: false` slows the suite.** Bounded — one module, and the alternative
  (allowances) can't work when the call happens at mount.
- **The stub drifts from the real agent.** These tests assert Airo's behaviour
  given a shape, not that the shape is right. `control_test.exs` and live
  verification against a real host remain the check on the contract.

## Acceptance — met

- Ten tests over the eight surfaces. 555 total (+10), lint 17 (unchanged, all
  `duplicated_class_string`).
- **Reverting the `"secondary"` → `"soft"` fix fails the regression test with
  `** (KeyError) key "secondary" not found`** — the production error, verified
  by actually reverting it and running. This was the criterion that mattered: a
  test that wouldn't have caught the bug it was written for is theatre.

## Deferred

- **The context-driven VRAM block.** The shipped test reaches `fits?: false`
  via the *weights floor* — a model too large for the card — which needs no
  form interaction. The other route, where a calibrated per-context cost pushes
  a resident model over budget, needs `config_change` to move the assign, and
  from `LiveViewTest` it doesn't: neither a raw `render_change/3` nor a
  `form/3`-driven change updates `ctx` (verified by rendering the slider, which
  stays at its prefill). The handler is one clause with no catch-all and it
  doesn't crash, so the event is arriving and the assign isn't moving —
  unresolved. Worth an hour with fresh eyes, because it also means **no test
  can currently drive that modal's form at all**, which is a second hole in the
  same page.
- Same seam for `LocalModels` and the prober, which have the identical problem.
