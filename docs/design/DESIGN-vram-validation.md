# Airo — VRAM validation & context legibility (S21)

> **Status: shipped (S21).** Historical sprint hand-off; describes implemented behavior.

Spec for **S21 — VRAM validation**. Implements `airo_agent/DESIGN.md` issues
**A4** (VRAM-fit validation) and **A2** (context/parallel legibility). Companion
to [DESIGN-slot-config.md](./DESIGN-slot-config.md) (S20, the config modal) and
[DESIGN-agent-placement.md](./DESIGN-agent-placement.md) (S18, capacity).

> **Goal (one sentence):** before loading/reconfiguring a slot, **hard-block** a
> context that won't fit the host's VRAM — and make the context/parallel/KV-quant
> reality legible — because over-committing the KV cache doesn't fail soft, it
> **segfaults** llama-server.

> **Why now.** Contract A makes `ctx` the per-request window and the engine's
> `-c = ctx × parallel`, so **VRAM scales with `ctx_total = ctx × parallel`**.
> An over-large total OOMs on the KV `cudaMalloc` and llama-server **segfaults**
> (observed 2026-06-22: `ctx 146432, parallel 4 ⇒ -c 585728`), with `-ngl 999`
> blocking auto-fit. S20 lets an operator drag the context up; nothing stops them
> from dragging it into a crash. This adds the guard.

---

## 1. The VRAM model — calibrate from the live measurement

Estimating KV size from first principles needs GGUF arch dims the agent doesn't
expose (and would still miss KV-quant / flash-attn / MTP effects). So Airo
**calibrates from the agent's live telemetry** — model-agnostic, captures every
real cost:

```
weights_mb        = inventory size_bytes / 2^20            # the model's weights
nonweights_mb     = vram_used_mb − weights_mb              # KV + buffers + MTP draft + overhead
per_ctx_mb        = nonweights_mb / ctx_total              # measured cost per KV token
projected(ctx_total') = weights_mb + per_ctx_mb × ctx_total'
fits?(ctx_total') = projected ≤ vram_total_mb × @margin    # @margin = 0.95
```

`ctx_total' = chosen_ctx × parallel`. Because `nonweights_mb` is measured on this
GPU with this model's actual KV quant (`q8_0`), flash-attn, and MTP draft, the
projection needs none of that detail.

## 2. Two cases (be honest about confidence)

- **Configure the resident model** (the slider's main use, and the documented
  danger): the model is `up`, so we have `weights`, `vram_used`, and the current
  `ctx_total` → calibrate → project the new `ctx_total` → **HARD-BLOCK** when it
  exceeds the budget. Exact.
- **Load a cold model** (or swap): nothing to measure for it. **Hard-block only on
  the definite weights floor** — `weights_mb > vram_total_mb × @margin` (after
  reclaiming the outgoing model on a swap, per S18). The KV portion is shown but
  marked **"not validated (cold model)"** — we don't fabricate a hard block from a
  guess. (Once loaded, reconfiguring becomes the exact case.)

## 3. Fixed decisions

- **Hard limit.** When the projection exceeds budget for a calibrated case, the
  load is **blocked** — the submit is disabled and the reason shown. Not advisory.
  Rationale: over-commit segfaults; a false block is safe, a false allow crashes.
- **Margin.** Validate against **95%** of `vram_total_mb` (leave headroom for
  fragmentation / non-KV growth).
- **Calibrate, don't model.** No arch-based KV formula; calibrate from live
  telemetry (§1). Cold models get the weights floor only (§2).
- **Profile facts are display-only.** `cache_type_k/v`, `flash_attn`, `spec_type`
  affect VRAM but are captured implicitly by calibration; the UI shows them (A2)
  for legibility, they don't enter the math.

## 4. Groundwork — ingest the new fields

The agent already sends them; Airo must capture them.
- **`SlotState`** gains `ctx_total` and `profile` (the `resolved_profile` map:
  `cache_type_k/v`, `flash_attn`, `spec_type`, …). `ctx_total` rides slot events;
  `profile` rides the (heartbeat) register, so `SlotState.put` **preserves**
  `profile` when a push omits it.
- **`Ingest.apply_slot`** passes `slot["ctx_total"]` and `slot["profile"]` through.

## 5. `Airo.Agents.Capacity` — context-aware

Add to the S18 module:
- `per_ctx_mb(weights_mb, vram_used_mb, ctx_total)` → measured cost/token or nil.
- `project(weights_mb, per_ctx_mb, ctx_total')` → projected MB.
- `validate(opts)` → `%{projected_mb, budget_mb, fits?: true|false|:cold}` where
  `:cold` means "weights fit but KV unvalidated." Keep `assess/3` (S18) for the
  list view; this is the load-time check.

## 6. UI

- **A2 legibility** — slots table + model list + config modal show
  **"`ctx` per request × `parallel` = `ctx_total` total"**, and the serving
  profile as tags: **KV `q8_0`**, **flash-attn**, **MTP** (`spec_type`).
- **A4 validation** — in the config modal, the context slider drives a
  **projected-VRAM meter** (`projected / total`, pressure-colored). When the
  calibrated projection exceeds budget, the meter reads error, a reason shows
  ("Needs ~X GB, only Y GB free — reduce context"), and **"Restart with
  changes" / "Load model" is disabled** (hard block). Cold models show the
  weights floor + a "context fit not validated" note.

## 7. Non-goals

- Per-model KV learning/persistence across loads (cold models stay weights-floor).
- An agent-side pre-flight VRAM guard (defense-in-depth; needs GGUF metadata).
- `parallel` editing (v1 config is still `ctx`-only; `parallel` shown, from the slot).
- Automatic placement/eviction on dispatch — out of scope (not planned).

## 8. Definition of Done

- Reconfiguring the resident model to a context that exceeds 95% of VRAM is
  **blocked** with a clear reason; a fitting context is allowed and the
  projected-VRAM meter tracks the slider.
- Slots/models/modal show per-request × parallel = total and the KV-quant /
  flash-attn / MTP tags.
- `Capacity` projection + validation unit-tested (calibrated fit, over-budget
  block, cold-model weights floor); `SlotState` carries `ctx_total`/`profile`.
- `mix precommit` + `mix joby_kit.lint` green; sprint file ticked; `docs/sprints/STATUS.md` updated.
