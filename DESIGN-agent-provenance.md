# Airo — Resident-model identity & provenance (S19)

Spec for **S19 — Resident-model identity & provenance**. Companion to
[DESIGN-agent-management.md](./DESIGN-agent-management.md) (S17, slot state + the
control client this builds on). Implementation hand-off: self-contained, names
exact files/functions, fixes the decisions.

> **Goal (one sentence):** make the agent's model identity canonical in Airo — a
> resident model carries its real id + provenance and its serving-instance facts,
> so the Model Shelf record is correct and a loaded model's deployment matches and
> reads `up` (today it reads `down`/"Avoid" while serving traffic).

> **Why now.** Airo keys models/deployments on a hand-typed/filename string
> (`Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf`); the agent knows the truth
> (`unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_XL` + sha + family/quant/size/ctx).
> `Ingest` marks a deployment `up` only on an exact `model_name == resident_model`
> match, so this model shows **down** and guidance says **"Avoid"** — while it has
> served 10 requests. The fix is to adopt the agent's identity and provenance.

---

## 1. The two tiers (the core distinction)

The "richer data" the agent sends is **two different things** with two homes:

| Tier | Meaning | Source | Fields | Home |
|---|---|---|---|---|
| **Model provenance** | static, per-artifact identity | inventory (join by resident id) | `revision` (HF sha), `family`, `quant`, `size_bytes`, `ctx_max` | `Model` |
| **Serving instance** | runtime, per-load facts | slot push (**already shipping**) | `ctx`, `parallel`, `engine_build`, `status`, `started_at` | `SlotState` |

The distinction is real: `ctx_max` (262144) is the model's GGUF ceiling; `ctx`
(65536) is the operator's launch choice; `parallel` (4) shares that context across
sequences; `engine_build` (`b1-9633186`) pins the llama.cpp binary. Together,
**`revision × engine_build × ctx/parallel` identify a reproducible serving
instance** — which is what performance should eventually attribute against.

This is Airo-side only: the agent's slot push already carries the serving facts,
and `/inventory` already carries the provenance. No `airo_agent` change.

## 2. Fixed decisions (do not re-litigate)

- **The agent's identity is canonical.** `Model.upstream_model_id` becomes the
  agent's `id` (`repo:quant`, e.g. `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_XL`);
  `Model.revision` = the HF sha. Keying on `repo:quant` (not bare `repo`) is v1; a
  `repo`-lineage grouping with quant-as-variant is a non-goal (§6).
- **Legacy records reconcile by GGUF filename.** An existing Model/Deployment whose
  name is the GGUF filename (`…UD-Q4_K_XL.gguf`) is matched to the resident model
  whose inventory `path` basename equals it, then **re-keyed** to the canonical id
  + enriched. One-time on reconcile; the push keeps it aligned after.
- **Provenance vs serving stay separate.** `Model` gets static provenance;
  `SlotState` gets serving facts. Config (`Deployment`) is **not** rewritten from
  runtime — serving `ctx`/`parallel`/`engine_build` live only in `SlotState`.
- **Identity match drives health, not the string.** `Ingest` marks a deployment
  `up` when it is identified with the resident model (by canonical id), not by a
  raw `model_name` string compare.
- **No new agent contract.** Serving facts come from the slot push; provenance
  from `/inventory` joined by id (fetched on register, infrequent).

## 3. Serving facts → `SlotState`

Extend `Airo.Agents.SlotState` records with `ctx`, `parallel`, `engine_build`
(already in the slot push). `Ingest.apply_slot` writes them through. The `/agents`
slot view surfaces them: **`ctx 65536 of 262144 max · parallel 4 · engine b1-9633186`**.

## 4. Provenance + identity → `Model` (the reconciliation)

New `Airo.Agents.Provenance` (or extend `Agents`):

1. On **register**, fetch `/inventory` once (cached for the call), build an id →
   provenance map.
2. For each slot with a `resident_model`, resolve provenance and **reconcile the
   Model**:
   - find the Model by canonical id (`upstream_model_id == resident_id`), else by
     **filename** (`path` basename == an existing Model/Deployment name) → re-key
     it to the canonical id, else create one;
   - enrich `revision`, `family`, `quantization` (`quant`), `size` (humanized
     `size_bytes`); set `display_name` if it's still the filename.
3. **Identify the slot's deployment** with that Model so `Ingest` health marks it
   `up` when resident. (`Deployment.model_name` aligns to the canonical id, or the
   match keys on `model_id`.)
4. Persist a provenance event / version row keyed on `revision` (+ `engine_build`)
   so the shelf's version performance attributes correctly.

Health then follows identity, not the legacy string — the model reads `up` and
Family/Revision/Quantization/Size populate.

## 5. UI

- **Model page (`/admin/models/:id`):** Family/Revision/Quantization/Size populate
  from provenance; Health reads `up`; "Avoid" clears. (`ctx_max` shown from
  provenance.)
- **Agent slot (`/agents/:id`):** serving facts row — effective `ctx` of `ctx_max`,
  `parallel`, `engine_build` paired with the model `revision`.

## 6. Non-goals (deferred)

- **`repo`-lineage grouping** (one Model spanning quants/revisions as variants).
- **Per-(revision × engine_build) performance attribution depth** — store the pair
  now; the comparison UI is later.
- **Spark unified-memory** (carried from S18).
- **Automatic placement & eviction** — now **S20**.

## 7. Definition of Done (sprint-specific)

- A resident model whose deployment was filename-named reconciles to the canonical
  id, reads `up`, and shows Family/Revision/Quantization/Size; "Avoid" clears
  (Model 13 / deployment 18 heal).
- `SlotState` carries `ctx`/`parallel`/`engine_build`; the agent slot view shows
  them paired with `revision`.
- Reconciliation + the filename re-key are unit-tested (incl. the legacy path);
  `Ingest` health keys on identity, not the raw string.
- `mix precommit` + `mix joby_kit.lint` green; `SPRINTS.md` ticked.
