# S18 — Host capacity & memory-fit

**Status:** [x] done  
**Branch:** `sprint/18-host-capacity-memory-fit`  
**Design:** [DESIGN-agent-placement.md](../design/DESIGN-agent-placement.md)

## Scope

Builds on S17 (merged).
Make packing several models onto one host safe: surface memory headroom, estimate
whether a requested load fits, and **warn** before an over-budget load — no
auto-load, evict, or block.
- **`Airo.Agents.Capacity`** (pure, no I/O): `footprint_mb(size_bytes)`
  (`size_bytes × 1.2` margin), `headroom(gpu)` (`total/used/free_mb` or
  `:unavailable`), `assess(size_bytes, gpu, reclaim_bytes)` → `%{footprint_mb,
  free_mb, fits?}` (swap-aware; `fits?: :unknown` with no telemetry)
- **No new data:** `/inventory` already reports `size_bytes`; `agent.gpu` already
  carries `vram_total/used_mb`; `SlotState` knows the resident model — pure
  Airo-side arithmetic over what S17 ships
- **`/agents/:id`:** free/total headroom on the GPU panel; inventory picker shows
  per-model footprint + an advisory `won't fit` tag (swap-aware), fits-first sort;
  **Load stays enabled** (advisory). Degrades to footprint-only with no telemetry
- **Fixed:** footprint = weights × 1.2; advisory only (never block); budget = live
  telemetry. Automatic placement/eviction is out of scope; Spark unified-memory budget
  deferred (memory is reported differently there)
- **DoD extra:** `Capacity` unit-tested (footprint, headroom incl. `:unavailable`,
  empty-slot vs swap assess, no-telemetry `:unknown`); picker shows footprint +
  swap-aware warning; Load never blocked
- _Complete: `Airo.Agents.Capacity` (pure; 10 tests); `/agents/:id` shows
  free/total headroom + per-model footprint with a swap-aware advisory `won't fit`
  tag, fits-first; Load never blocked. precommit + joby_kit.lint green (341 tests).
  Verified live against jobycorp (2.8 GB free, 25.5 GB resident): swap reclaims the
  outgoing footprint so no false warning; empty-slot load of the same model
  correctly reports `fits?: false`._
