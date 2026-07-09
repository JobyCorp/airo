# S12 — Model Shelf

**Status:** [x] done  
**Branch:** `sprint/12-model-shelf`  
**Design:** [DESIGN-model-shelf.md](../design/DESIGN-model-shelf.md)

## Scope

A model-management layer over the gateway so Airo can answer operational and
evaluation questions about model artifacts, versions, deployments, and routing
posture across many local machines.

## Outcome

Shipped as an observational shelf over durable `Model` identity; routing unchanged.

- `Airo.Config.Model` + deployment `model_id` link; lifecycle statuses
- `Airo.ModelShelf` + `/admin/models` list/detail (copies, aliases, health, traces,
  version cohorts, guidance)
- `Airo.LocalProvider` / `Airo.LocalModels` with Ollama, LM Studio, vLLM, Infinity,
  Speaches adapters; manual Sync from model/provider UI
- Usage snapshots enable version before/after comparison
- DoD: one model across two providers with aggregate + per-row performance (tested)

_Complete: closed 2026-07-09. Optional deferred work (scheduled sync, list polish,
pull UI, subjective scoring, etc.) is listed in DESIGN-model-shelf.md §6 — not
committed; revisit in the next project deep dive._
