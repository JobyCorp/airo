# Airo — Resident-model identity & provenance (S19)

> **Status: shipped (S19).** Historical sprint hand-off; describes implemented behavior.

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

## 1a. Scope — agent-managed providers only

This sprint touches **only agent-managed slot providers** (`Provider.agent_id`
set). External/unmanaged providers (`agent_id = null` — vLLM, Ollama, Anthropic,
OpenAI, Infinity, Speaches…) have no slot, no agent push, and no inventory, so:

- their `Model.upstream_model_id` stays **as today** (the upstream id, e.g.
  `gpt-4o`) — never host/slot-qualified;
- their health stays **prober-driven** (the prober skips only agent providers);
- their `Model`-as-artifact / many-deployments grain is unchanged.

This is structurally enforced: all reconciliation is driven from
`Ingest.apply_slot`, which only runs for agent pushes. The **legacy filename
re-key (§4) must be guarded to the slot's own provider/deployments** so it can
never wander onto an external provider's Model.

## 2. Fixed decisions (do not re-litigate)

- **Identity is host-qualified; name/id are separate concepts.** The agent's model
  id (`repo:quant`) is the *real model name*, and it is **not unique** — the same
  model is copied across hosts for distribution/failover. So:
  - **`Model.upstream_model_id`** (the unique key Airo matches/keys on) is
    **host-_and_-slot-qualified**: `<host_id>_<agent_model_id>_<slot>` (e.g.
    `jobycorp_unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_XL_8081`). Collision-free
    across distributed copies — and across slots, so the same model loaded into two
    slots on one host stays two distinct records (no footgun), even though there's
    no current need for that.
  - **`Model.display_name`** (and any alias) is the **real model name** (the
    agent's `repo:quant`), which may repeat across hosts.
  - `Model.revision` = the HF sha. Keying the *name* on `repo:quant` (not bare
    `repo`) is v1; a `repo`-lineage grouping is a non-goal (§6).
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

## 3. Serving facts → `SlotState` (captured, not the focus)

The serving instance facts (`ctx`, `parallel`, `engine_build`) are **noted** this
sprint, not built out: extend `Airo.Agents.SlotState` to carry them from the slot
push so the data isn't dropped, but the sprint's focus is provenance/identity (§4).
A richer serving-facts surface (effective `ctx` of `ctx_max`, `parallel`,
`engine_build × revision` reproducibility, per-pair performance) is a later pass.

## 4. Provenance + identity → `Model` (the reconciliation)

New `Airo.Agents.Provenance` (or extend `Agents`):

1. On **register**, fetch `/inventory` once (cached for the call), build an id →
   provenance map.
2. For each slot with a `resident_model`, resolve provenance and **reconcile the
   Model**. The unique key is `host_id <> "_" <> resident_id <> "_" <> slot` (slot =
   port):
   - find the Model by that host/slot-qualified `upstream_model_id`, else by
     **filename** (`path` basename == an existing Model/Deployment name) → re-key it
     to the qualified id, else create one;
   - set `display_name` = the real model name (`resident_id`); enrich `revision`,
     `family`, `quantization` (`quant`), `size` (humanized `size_bytes`).
3. **Identify the slot's deployment** with that Model so `Ingest` health marks it
   `up` when resident — health keys on identity (`model_id`), not a raw
   `model_name` compare. Grain: the key is **(host, model, slot)**, so every
   serving location is its own Model record; copies — across hosts or across slots
   on one host — never collide and simply share a `display_name`.
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
- **Automatic placement & eviction on dispatch** — out of scope (not planned).

## 7. Definition of Done (sprint-specific)

- A resident model whose deployment was filename-named reconciles to the canonical
  id, reads `up`, and shows Family/Revision/Quantization/Size; "Avoid" clears
  (Model 13 / deployment 18 heal).
- `SlotState` carries `ctx`/`parallel`/`engine_build`; the agent slot view shows
  them paired with `revision`.
- Reconciliation + the filename re-key are unit-tested (incl. the legacy path);
  `Ingest` health keys on identity, not the raw string.
- `mix precommit` + `mix joby_kit.lint` green; sprint file ticked; `docs/sprints/STATUS.md` updated.
