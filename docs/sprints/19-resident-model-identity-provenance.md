# S19 — Resident-model identity & provenance

**Status:** [x] done  
**Branch:** `sprint/19-resident-model-identity-provenance`  
**Design:** [DESIGN-agent-provenance.md](../design/DESIGN-agent-provenance.md)

## Scope

Depends on S17.
Make the agent's model identity canonical: a resident model carries its real id +
provenance and its serving-instance facts, so the Shelf is correct and a loaded
model's deployment reads `up` (today it reads `down`/"Avoid" while serving). The
agent already pushes the data — Airo-side only.
- **Two tiers, two homes:** *model provenance* (static — `revision`, `family`,
  `quant`, `size`, `ctx_max`; from `/inventory` joined by resident id) → `Model`;
  *serving instance* (runtime — `ctx`, `parallel`, `engine_build`; from the slot
  push, already shipping) → `SlotState`
- **`SlotState` + `Ingest`:** carry `ctx`/`parallel`/`engine_build` through; the
  agent slot view shows effective `ctx` of `ctx_max` · `parallel` · `engine_build`
  paired with `revision`
- **Reconciliation:** on register, join inventory by resident id → enrich the
  `Model` (canonical `upstream_model_id` = `repo:quant`, `revision`, `family`,
  `quantization`, `size`); identify the slot's deployment so health keys on
  identity not the raw string; **legacy repair** re-keys filename-named records via
  the GGUF `path` basename
- **Fixed:** agent identity canonical (`repo:quant`); provenance vs serving stay
  separate (config not rewritten from runtime); no agent change
- **DoD extra:** Model 13 / deployment 18 heal (`up`, provenance populated, "Avoid"
  clears); reconciliation + filename re-key unit-tested; Ingest health keys on
  identity
- _Complete: `Airo.Agents.Provenance.reconcile/4` (host_model_slot key,
  display_name = real name, revision/family/quantization/size enrichment, legacy
  filename re-key guarded to the slot provider, deployment linked by real-id or
  filename; 6 tests). `SlotState` carries ctx/parallel/engine_build; `Ingest`
  joins `/inventory` per register/slot and derives health by `model_id` identity.
  Verified live: jobycorp's model healed to `up`, host-qualified id, full
  provenance, guidance flipped Avoid→Candidate. precommit + joby_kit.lint green
  (347 tests). Deferred: serving-facts UI, repo-lineage grouping, revision×build
  perf attribution._
