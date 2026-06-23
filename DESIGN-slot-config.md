# Airo — Slot configuration & reload (S20)

Spec for **S20 — Slot configuration & reload**. Companion to
[DESIGN-agent-management.md](./DESIGN-agent-management.md) (S17 control plane) and
[DESIGN-agent-provenance.md](./DESIGN-agent-provenance.md) (S19, `ctx_max` and
identity). Implementation hand-off: self-contained, fixes the decisions.

> **Goal (one sentence):** let an operator configure how a model is served on a
> host slot — starting with the context window — and load or restart it, from an
> always-visible model list with a focused config modal.

> **Why now.** S17 made loads deployment-free but **profile-less** ("default
> profile for now"). The real control is choosing the serving profile per load —
> first the context window (`ctx`), which trades capability for memory. And the
> S17 picker hid the model list behind a per-slot click; it should always be
> visible.

---

## 1. What's already there

- The agent's `POST /load` takes a `profile` map; `ctx` is a profile key (with
  `parallel`, `flash_attn`, … for later). `Control.load/3` currently sends **no**
  profile (agent default).
- `SlotState` carries the live serving `ctx` (and `parallel`, `engine_build`);
  `Model` carries `ctx_max` provenance (S19) — the ceiling for the control.
- Inventory (`Control.inventory`) lists loadable models with `size_bytes`,
  `ctx_max`, etc.; `Capacity` (S18) estimates fit.

## 2. Fixed decisions

- **v1 config = context window only.** `profile = %{ctx: n}`. The modal is built
  to grow (more profile keys later), but ships with `ctx`.
- **Configure = reload.** Configuring the resident model = `load` the same model
  into its slot with the new profile; the agent restarts it (implicit
  unload→load). It **interrupts in-flight requests** on that slot — the modal says
  so. No drain (carried from S17).
- **Model list is always visible.** Loadable models render whenever the host is
  online, each with **Load** (not resident) or **Configure** (resident). No hidden
  picker.
- **One modal for both.** Load and Configure open the same config modal; the verb
  and prefill differ (Load → empty/`ctx_max`; Configure → current `ctx`).
- **Slot targeting.** The modal targets a slot: for Configure it's the resident
  slot; for Load it's the chosen slot — preselected when the host has one slot, a
  selector when it has several.
- **`ctx` bounds.** `1 ≤ ctx ≤ ctx_max` (when `ctx_max` known); advisory only —
  never blocks (consistent with S18). Empty `ctx` ⇒ agent default.

## 3. New wrapper — `<.modal>`

JobyKit ships no modal. Wrap daisyUI's `<dialog class="modal">` as a registered
composite `AiroWeb.CompositeComponents.modal`:

- attrs: `id` (required), `show` (boolean — open state, LiveView-driven), `on_cancel`
  (a `JS`/event), `title` slot, `inner_block`, `actions` slot; `data-component`,
  `attr :rest, :global`.
- Backdrop + Esc close to `on_cancel`; focus the dialog on open; reduced-motion
  respected. Registered in `DesignManifest` (+ preview).

## 4. Control + reconciliation

- `Control.load/4` gains a `profile` map: `POST /load {model, slot, profile}`.
  `Control.load(agent, port, model_id, ctx: n)` builds `%{ctx: n}` (drop nils).
- The LiveView `load`/`configure` events build the profile from the modal form,
  call `Control.load`, flash, and clear the modal. The transition arrives by push
  (S17); `SlotState` reflects the new `ctx`.

## 5. UI — `/agents/:id`

- **Slots** table gains a **Configure** action (resident only) and keeps Unload;
  show the live `ctx` (of `ctx_max`).
- **Models on this host** — a new always-visible section listing inventory
  (online only): model · footprint (S18 fit) · **Load**/**Configure**.
- **Config modal** (the signature): "Load *name*" / "Configure *name*" with a
  **context-window control shown against `ctx_max`** — reuse the `meter` visual so
  ctx-of-max reads at a glance. Primary action **Load model** / **Restart with
  changes**; Configure carries the interrupt note. Degrades when telemetry/ctx_max
  is unknown (plain number input, no ceiling).
- Offline host ⇒ list shown read-only, actions disabled (S17 pattern).

## 6. Non-goals (deferred)

- Profile keys beyond `ctx` (parallel, flash_attn, KV-quant, jinja, …).
- Drain-on-restart; automatic placement (S21); Spark unified-memory.

## 7. Definition of Done

- Models list is always visible online; each model has Load or Configure.
- Load opens the modal, sets a context window, and loads with that `ctx`;
  Configure opens prefilled with the current `ctx` and restarts the slot; the new
  `ctx` shows in `SlotState`/slots after the push.
- `<.modal>` registered + lint-clean; `Control.load/4` profile unit-tested
  (profile sent, nils dropped) against a stubbed Req plug.
- `mix precommit` + `mix joby_kit.lint` green; `SPRINTS.md` ticked.
