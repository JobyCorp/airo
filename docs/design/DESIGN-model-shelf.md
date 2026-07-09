# Airo — Model Shelf (S12)

> **Status: shipped (S12).** As-built reference. Optional follow-ups listed in §6
> are **not committed** — revisit during the next project deep dive.

Companion to [DESIGN.md](./DESIGN.md) §8 / §10. Routing stays in the Alias plane;
the shelf is a read model over durable model identity + deployment copies + usage.

> **Goal (one sentence):** give operators one place to evaluate a model artifact
> across machines — copies, health, routing participation, and version cohorts —
> without changing how aliases route traffic.

---

## 1. Core distinction

| Concept | Meaning | Home |
|---|---|---|
| **Model** | Durable artifact/version identity operators evaluate | `Airo.Config.Model` |
| **Deployment** | Runnable copy of that model on a provider/machine | `Airo.Config.Deployment` (`model_id`) |
| **Alias routing** | Who gets traffic | Unchanged — Alias → candidates → deployments |

Lifecycle statuses: `:evaluating | :preferred | :deprecated | :disabled`.

---

## 2. Modules (as-built)

| Module | Role |
|---|---|
| `Airo.Config.Model` | Schema + changeset |
| `Airo.Config` | CRUD; `ensure_model_id/1` on deployment create; `list_models_with_deployments/0` |
| `Airo.ModelShelf` | Read model: list summaries, detail (deployments, aliases, health, traces, version cohorts, guidance) |
| `Airo.LocalProvider` | Optional callbacks: `catalog`, `inspect_model`, `pull_model`, `runtime_info` |
| `Airo.LocalModels` | Facade: `sync_deployment/1`, catalog/inspect/pull/runtime |
| Adapters | Ollama, LM Studio, vLLM, Infinity, Speaches (+ Unsloth via vLLM) |

Migrations: `create_models_and_link_deployments`, `add_model_snapshot_to_usage_records`,
`add_provider_metadata_to_deployments`.

---

## 3. Admin surfaces

| Route | LiveView | What |
|---|---|---|
| `/admin/models` | `Admin.ModelLive` | Shelf list + CRUD |
| `/admin/models/:id` | `Admin.ModelLive` | Detail: copies, aliases, health, traces, version cohorts, Sync |
| `/admin/providers/:id` | `Admin.ProviderLive` | Local catalog, runtime/loaded inventory, Sync |

Manual sync: `LocalModels.sync_deployment/1` → inspect + runtime → update model
fields (`family` / `quantization` / `size` / `revision`) + `deployment.provider_metadata`
(includes `synced_at`).

---

## 4. Evaluation (v1)

- Usage rows snapshot `model_version` / `model_revision` at write time.
- `ModelShelf.version_summaries/1` groups cohorts for before/after comparison.
- Per-deployment guidance scores (“Lean on” / “Candidate” / “Avoid”) from usage + health.
- Subjective quality scoring: **not built** (optional backlog).

---

## 5. Fixed decisions

- Shelf does **not** change routing; aliases remain source of truth.
- Local providers first; cloud catalog/control stays out of scope.
- Sync is **operator-triggered** in v1 (no scheduled worker).
- Agent slot load/unload stays on `/admin/agents` (not LM Studio load UI on the shelf).
- Slot-resident models without a deployment row are still shelf-visible via
  `ModelShelf.resident?/1` + provenance.

---

## 6. Optional deferred (revisit in deep dive)

Not blocking. May be dropped or reshaped:

- Scheduled metadata refresh (Oban) + persisted `sync_error`
- Shelf list-card polish (p50 / fallback / cost already on detail)
- Admin UI for `pull_model` (adapter API exists)
- Trace-id links from model detail → `/admin/logs/:trace_id`
- Subjective quality scoring
- LM Studio load/unload from provider pages (agent plane owns load today)
