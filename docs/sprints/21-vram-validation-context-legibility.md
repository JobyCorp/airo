# S21 — VRAM validation & context legibility

**Status:** [x] done  
**Branch:** `sprint/21-vram-validation-context-legibility`  
**Design:** [DESIGN-vram-validation.md](../design/DESIGN-vram-validation.md)

## Scope

Implements
airo_agent A4 (VRAM-fit) + A2 (legibility). Depends on S18 (capacity) + S20 (config).
Hard-block a context that won't fit VRAM before loading — over-commit segfaults
llama-server (KV `cudaMalloc` OOM) — and make ctx/parallel/KV-quant legible.
- **Calibrated VRAM** (no arch formula): `per_ctx = (vram_used − weights)/ctx_total`
  from live telemetry; `projected = weights + per_ctx × ctx_total'`; fits =
  `projected ≤ vram_total × 0.95`. Captures KV-quant/flash-attn/MTP implicitly
- **Two cases:** resident reconfigure → calibrated **hard block** (exact, the
  documented danger); cold load → weights-floor hard block + KV "not validated"
- **Groundwork:** `SlotState`/`Ingest` ingest `ctx_total` + `profile`
  (`resolved_profile`); `profile` preserved when a push omits it
- **`Capacity`:** `per_ctx_mb`, `project`, `validate` → `fits?: true|false|:cold`
- **UI:** A2 — slots/list/modal show "ctx per-request × parallel = total" + tags
  (KV `q8_0`, flash-attn, MTP); A4 — config modal projected-VRAM meter, submit
  **disabled** with a reason when over budget
- **Fixed:** hard limit (not advisory); 95% margin; calibrate not model
- **DoD extra:** an over-budget reconfigure is blocked with a reason; a fitting one
  allowed; `Capacity` projection/validation + cold-floor unit-tested
- _Complete: `Capacity.per_ctx_mb`/`project`/`validate` (calibrated; 15 tests incl.
  cold floor + over-budget); `SlotState`/`Ingest` carry `ctx_total` + `profile`
  (profile preserved across pushes). UI: slots show "ctx × parallel = total" + KV/
  flash-attn/MTP tags; config modal projects VRAM as the slider moves and **hard-
  blocks** (disabled submit + server guard) over the 95% budget. Verified live on
  jobycorp: at 146432 → 27.2/30.3 GB allowed; at max 262144 → 31.8/30.3 GB blocked
  ("reduce the context"). 354 tests, precommit + joby_kit.lint green. Deferred:
  per-model KV learning, parallel editing, agent-side pre-flight guard._
