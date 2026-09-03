# Airo — Sprint process

Lightweight, scope-boxed process for standing up Airo. Architecture lives in
[`docs/design/`](../design/DESIGN.md).

## Cadence

Every feature-sized change follows this loop:

```
Design  →  Sprint  →  Branch  →  Squash merge  →  Close
```

1. **Design** — Capture or update the decision in [`docs/design/`](../design/).
   A sprint that changes architecture needs a design note (or an update to an
   existing one) *before* implementation starts. Small clarifications can land
   in the same PR as the sprint; new surfaces get their own design doc.
2. **Sprint** — Open a sprint file under [`docs/sprints/`](./) with a one-sentence
   goal, deliverables, dependencies, and DoD extras. Mark it `[ ]` in this index.
3. **Branch** — One sprint = one branch named `sprint/NN-slug`
   (e.g. `sprint/00-foundations`). Implement only that sprint's scope.
4. **Squash merge** — When Definition of Done is met, squash-merge to `main`.
   `main` always compiles. Append a line to [`STATUS.md`](./STATUS.md).
5. **Close** — Tick the sprint checkbox (`[x]`), note completion in the sprint
   file if useful, and delete the branch.

### Out of band (no sprint required)

These may commit straight to `main` (or a short-lived fix branch) **without**
the Design → Sprint loop:

- Minor fixes (typos, small refactors that don't change behavior)
- Docs cleanup (link fixes, wording, reorg)
- Bug fixes that restore intended behavior without expanding scope

If a "bug fix" needs a new design decision or grows past a few files, promote
it to a sprint.

## Definition of Done (every sprint)

- [ ] `mix precommit` green (`compile --warnings-as-errors`, `deps.unlock --unused`,
      `format`, `test`)
- [ ] New behavior has tests (adapters tested against a stubbed Req plug, not live)
- [ ] `mix joby_kit.lint` green *if the sprint touched UI*
- [ ] Design docs updated if any decision changed
- [ ] Sprint file ticked `[x]`; status-log line appended
- [ ] Branch squash-merged to `main` and pushed

## Definition of Ready (before starting a sprint)

- Goal is one sentence; deliverables are listed; it depends only on merged sprints.
- Design note exists (or an explicit "no design change" call in the sprint file).

## Commits

- Keep the subject imperative and scoped to the sprint.
- End commits with the co-author trailer when applicable.

---

## Backlog

Ordered — each depends on prior merged sprints unless noted in the sprint file.

- [x] [S0 — Foundations & config plane](./00-foundations-config-plane.md)
- [x] [S1 — Transport & adapter behaviour](./01-transport-adapter-behaviour.md)
- [x] [S2 — Chat front door (first end-to-end slice)](./02-chat-front-door-first-end-to-end-slice.md)
- [x] [S3 — Streaming & transparency](./03-streaming-transparency.md)
- [x] [S4 — Routing core](./04-routing-core.md)
- [x] [S5 — Capability breadth](./05-capability-breadth.md)
- [x] [S6 — Observability & config UI](./06-observability-config-ui.md)
- [x] [S7 — Consumer migration](./07-consumer-migration.md)
- [x] [S8 — Realtime proxy](./08-realtime-proxy.md)
- [x] [S9 — `airo_client` package](./09-airo-client-hex-package.md) — git-only monolith; Hex deferred
- [x] [S10 — API docs (`/docs`)](./10-api-docs-docs.md)
- [x] [S11 — Gateway observability](./11-gateway-observability.md)
- [x] [S12 — Model Shelf](./12-model-shelf.md) — shipped; optional deferred in design §6
- [x] [S13 — Routed `chat` alias (classification-driven tiering)](./13-routed-chat-alias-classification-driven-tiering.md)
- [x] [S14 — Logging & traceability](./14-logging-traceability.md)
- [x] [S15 — Local ONNX classifier (Ortex, on-CPU validation slice)](./15-local-onnx-classifier-ortex-on-cpu-validation-slice.md)
- [x] [S16 — Routing settings (system-level classifier)](./16-routing-settings-system-level-classifier.md)
- [x] [S17 — Agent control plane (operator-driven)](./17-agent-control-plane-operator-driven.md)
- [x] [S18 — Host capacity & memory-fit](./18-host-capacity-memory-fit.md)
- [x] [S19 — Resident-model identity & provenance](./19-resident-model-identity-provenance.md)
- [x] [S20 — Slot configuration & reload](./20-slot-configuration-reload.md)
- [x] [S21 — VRAM validation & context legibility](./21-vram-validation-context-legibility.md)
- [x] [S22 — Engine parity & engine-aware capacity](./22-engine-parity-capacity.md)
- [x] [S23 — A test seam for the agent control plane](./23-agent-control-plane-test-seam.md)
- [x] [S24 — Site settings & health flap suppression](./24-site-settings-and-health-hysteresis.md)
- [ ] [S25 — Agent lifecycle observability](./25-agent-lifecycle-observability.md) — airo only; prod-deployable alone
- [ ] [S26 — Observer airos (one controller, N observers per agent)](./26-observer-airos.md) — airo + airo_agent; depends on S25

See [`STATUS.md`](./STATUS.md) for merge history.
