# S20 — Slot configuration & reload

**Status:** [x] done  
**Branch:** `sprint/20-slot-configuration-reload`  
**Design:** [DESIGN-slot-config.md](../design/DESIGN-slot-config.md)

## Scope

Depends on S17 + S19. Let an
operator configure how a model is served on a slot — starting with the context
window — and load/restart it, from an always-visible model list with a config modal.
- **`Control.load/4` profile:** `POST /load {model, slot, profile}`; v1
  `profile = %{ctx: n}` (nils dropped). Configure = load the resident model into
  its slot with the new profile → the agent restarts it (interrupts in-flight)
- **`<.modal>` wrapper:** wrap daisyUI `<dialog class="modal">` as a registered
  composite (backdrop/Esc close, focus, reduced-motion); + preview
- **`/agents/:id`:** always-visible "Models on this host" list (online) — each
  model has **Load** (not resident) or **Configure** (resident); slots gain a
  Configure action. The **config modal** shows the context window **against
  `ctx_max`** (reuse the `meter` visual); Load → "Load model", Configure →
  "Restart with changes" with an interrupt note. Offline ⇒ read-only
- **Fixed:** v1 = `ctx` only (extensible); advisory bounds `1..ctx_max`; no drain
- **DoD extra:** Load sets a ctx and loads; Configure prefills current ctx and
  restarts; new ctx shows after the push; `<.modal>` lint-clean; `Control.load/4`
  profile unit-tested vs a stubbed Req plug
- _Complete: `Control.load/4` profile (nils dropped; 11 tests); `<.modal>` wrapper
  (registered + preview); `/agents/:id` shows an always-visible "Models on this
  host" list (Load/Configure per model, resident-tagged), a Context column on
  slots, and a config modal with the context window shown against `ctx_max` (meter
  signature). Load/restart fire async (90s timeout, off the LiveView) so the slow
  blocking `/load` doesn't freeze the page — the slot transitions via push.
  Verified live (jobycorp): modal prefills 65536, meter 65536/262144, copy/flow.
  349 tests, precommit + joby_kit.lint green. Deferred: profile keys beyond ctx,
  fast-rejection feedback on async load, drain-on-restart._
