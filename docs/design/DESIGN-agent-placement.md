# Airo — Host capacity & memory-fit (S18)

> **Status: shipped (S18).** Historical sprint hand-off; describes implemented behavior. Automatic placement on dispatch is out of scope.

Spec for **S18 — Host capacity & memory-fit**. Companion to
[DESIGN-agent-management.md](./DESIGN-agent-management.md) (S17, the operator
control plane this builds on). Implementation hand-off: self-contained, names
exact files/functions, fixes the decisions.

> **Goal (one sentence):** make packing several models onto one host safe — Airo
> surfaces each host's memory headroom, estimates whether a requested load will
> fit (from inventory `size_bytes` + live GPU telemetry), and **warns** before a
> load that likely won't — without auto-loading, evicting, or blocking anything.

> **Why now.** S17 made loads *possible* but *unconditional*: an operator picks a
> slot and a model and the agent loads it, with nothing checking whether it fits
> alongside what's already resident. On a multi-slot box (e.g. a DGX Spark running
> a few small models at once) that's an easy out-of-memory. S18 adds the capacity
> awareness that makes multi-model packing deliberate instead of blind.

---

## 1. Why this is contained

No agent change and no new data source — everything needed already arrives:

- **`/inventory` already reports `size_bytes`** per model (`AiroAgent.ModelRef`
  → `model_json` serializes the whole struct), plus `ctx_max`, `quant`, `family`.
  `Airo.Agents.Control.inventory/2` already returns it.
- **GPU telemetry already carries `vram_total_mb` / `vram_used_mb`**, live on the
  agent record (`agent.gpu`) and refreshed by every register push.
- **`SlotState`** already knows each slot's `resident_model` id.

So S18 is pure Airo-side arithmetic + presentation over data we already have.

## 2. Fixed decisions (do not re-litigate)

- **Footprint is an estimate, not a measurement.** A model's memory footprint ≈
  `size_bytes × 1.2` — the weights are the floor; the ×1.2 margin is a flat
  allowance for KV-cache / context / runtime overhead. A ctx-aware estimate is a
  non-goal for v1.
- **Advisory only.** A load that doesn't fit the estimate is **warned**, never
  blocked. The operator can always proceed — the estimate is fuzzy and live
  telemetry (`vram_used_mb`, which already drives the red VRAM meter) is the real
  signal once loaded.
- **Budget = live telemetry.** `total = vram_total_mb`, `free = total − vram_used_mb`.
  `used` already reflects every resident model + overhead, so the only thing we
  estimate is the *incoming* model.
- **Swap frees the outgoing model.** Loading into an occupied slot unloads first,
  so the fit check adds the outgoing model's footprint back to `free` (looked up
  from inventory by `resident_model` id; treated as 0 if unknown — conservative).
- **No automatic placement or eviction.** Auto-loading the right model before
  serving, slot selection, and what-to-evict policy are out of scope, not this
  sprint.
- **Spark is out of scope for v1.** Unified-memory hosts (GB10) report memory
  differently from discrete-VRAM `nvidia-smi`; the budget there is a slice of
  system memory, not `vram_total`. v1 uses the existing fields; a Spark-aware
  budget is a recorded follow-up (§5).

## 3. `Airo.Agents.Capacity`

New pure module — no I/O, fully unit-testable.

```
@margin 1.2

footprint_mb(size_bytes)            # size_bytes / 1_048_576 * @margin, rounded; nil → nil
headroom(gpu)                       # %{total_mb, used_mb, free_mb} | :unavailable
assess(size_bytes, gpu, opts)       # opts[:reclaim_bytes] = outgoing model on a swap
  -> %{footprint_mb, free_mb, fits?: boolean} | %{footprint_mb, fits?: :unknown}
```

- `headroom/1` returns `:unavailable` when `gpu["available"] != true` or the
  fields are missing — callers then skip the fit verdict (show footprint only).
- `assess/3` computes `effective_free = free_mb + footprint_mb(reclaim_bytes)` and
  `fits? = footprint_mb <= effective_free`. With no telemetry, `fits?: :unknown`.

## 4. UI — `/agents/:id`

- **Headroom** on the GPU posture panel: a `free / total GB` readout beside the
  VRAM meter (the meter already shows used/total + pressure color).
- **Inventory picker** (per model row): show the **footprint** (`~X.X GB`) and,
  when telemetry is available, an advisory **"won't fit"** `tag` (tone `warning`)
  for models whose estimate exceeds effective free for *that* slot (swap-aware).
  **Load stays enabled** — advisory only. Sort fits-first so the viable choices
  lead.
- **Degrade gracefully:** offline host / no telemetry ⇒ footprint shown, no
  verdict, no false warnings.

## 5. Non-goals (deferred)

- **Automatic placement / eviction on dispatch — out of scope (not planned).**
- **Spark / unified-memory budget.** Detect unified-memory hosts and budget
  against system memory; the agent may need to report a memory-kind + total.
- **ctx-aware footprint** (KV-cache from `ctx_max` × layers × kv-quant).
- **Per-slot footprint column** (needs the resident model's size on the slot push,
  an agent change) — picker-side fit is enough for v1.

## 6. Definition of Done (sprint-specific)

- `Airo.Agents.Capacity` unit-tested: footprint math, headroom (incl.
  `:unavailable`), `assess` for empty-slot load and swap, and the no-telemetry
  `:unknown` path.
- The inventory picker shows per-model footprint and a swap-aware advisory "won't
  fit" tag; the GPU panel shows free/total; Load is never blocked.
- `mix precommit` + `mix joby_kit.lint` green; sprint file ticked; `docs/sprints/STATUS.md` updated.
