# Airo — Routing settings: system classifier (S16)

> **Status: shipped (S16).** Historical sprint hand-off; describes implemented behavior.

Spec for **S16 — Routing settings (system-level classifier)**. Companion to
[DESIGN-chat-routing.md](./DESIGN-chat-routing.md) (S13, the classifier + per-alias
`router_config`) and [DESIGN-local-classifier.md](./DESIGN-local-classifier.md) (S15,
the `:ortex` on-CPU backend). This is the implementation hand-off: self-contained,
names exact files/functions, and fixes the decisions so the build doesn't re-derive
them.

> **Goal (one sentence):** lift the classifier configuration out of each alias and
> into **one system-level "Routing" setting** — choose the engine (**local Ortex |
> remote Infinity**) and its model, the score weighting, the tier ladder, and test
> it, in a dedicated `/admin/routing` UI — so a routed alias only has to **opt in**
> (`router: :classify` + a `shadow|enforce` mode) and **inherit the system
> classifier**, instead of re-specifying it.

> **Why now.** S13 put the whole classifier config in `aliases.router_config`, so
> every routed alias re-specifies backend/model/weights/thresholds — duplication, and
> a concern-mix ("how the system grades prompts" vs "does this alias route"). S15 made
> it worse by adding `backend`/`model`/`score` keys the alias form (`build_router_config/1`,
> `alias_live.ex:122`) doesn't know about and **silently clobbers back to `:infinity`
> on save**. The classifier is a *system capability*; this sprint models it as one.

---

## 1. Why this is contained

The decision logic and both backends already exist and are validated — S16 **moves
config, it does not add inference**:

1. **The seam already takes one config map.** `Classifier.class_for/2`
   (`classifier.ex:46`) → `parse_config/1` → `score/2` (dispatch on `backend`) →
   `decide/2`. Today the map comes from `alias_.router_config`; S16 sources the same
   map from the system setting. `score_infinity/2`, `LocalClassifier.score/2`, and
   `decide/2` are **untouched**.
2. **Both engines ship.** `:infinity` (S13) and `:ortex` (S15) already produce the
   identical `%{class => score}` shape. The setting just picks which.
3. **The prompt-tester exists.** The alias page already has a no-traffic "test a
   prompt" path (`alias_live.ex` `handle_event "test"`); S16 moves it to `/admin/routing`.
4. **Fail-open is unchanged.** A missing/disabled system classifier ⇒ `class_for`
   returns `{:error,_}`/`:skip` ⇒ the gateway leaves routing untouched (today's
   behavior). No new failure mode.

## 2. Fixed decisions (do not re-litigate)

- **Singleton, not profiles.** One system classifier (`backend` + model + weighting +
  ladder). A `classifiers`-table with per-alias selection is a *non-goal* (§9) — revisit
  only if a "fast vs thorough" split is ever needed. The schema is shaped so that
  growth is additive (add a `name` + FK later), but v1 is a single row.
- **System owns the classifier; the alias owns participation.** System-level:
  `backend`, `model`/`classifier` ref, `score` weighting, the **tier ladder**
  (`labels` = class+min, ordered), `default_class`, `input`, `timeout_ms`. Per-alias:
  `router` (`:none|:classify`) and `router_mode` (`:shadow|:enforce`). Mode stays
  per-alias so enforce rolls out one alias at a time.
- **`aliases.router_config` is retired for the classifier.** Migrated into the
  singleton; the column is dropped (or left unused) — see §3. `aliases.router` stays.
- **Engine choice is the headline knob.** The UI's primary control is **Local
  (Ortex) | Remote (Infinity)**. Local ⇒ pick a `model` (from the `fetch_model`
  manifest) + edit the `score` dim-weights; Remote ⇒ pick a `:classify`-capability
  alias. Everything else (ladder, default_class, input, timeout) is shared.
- **Cache the setting; never DB-read per request.** Load the parsed system config into
  `:persistent_term` at boot and on every settings save (broadcast → reload). Routed
  requests read the cached struct.
- **Validation-first parity with S15.** Default backend stays whatever the migration
  carried (Infinity in prod today); flipping engine is a settings edit, enforce is a
  per-alias mode edit — neither is a deploy.

## 3. Data model

**New singleton schema** `Airo.Config.RoutingSetting` (`lib/airo/config/routing_setting.ex`),
table `routing_settings`, exactly one row (guard: fixed `id`/a `singleton` unique
boolean):

| field | type | notes |
|---|---|---|
| `backend` | `Ecto.Enum [:infinity, :ortex]` | engine |
| `classifier` | `:string` | infinity: the `:classify` alias name (nil for ortex) |
| `model` | `:string` | ortex: dir under `priv/models/` (nil for infinity) |
| `score` | `:map` | ortex weighting: `%{dim => weight}` or `"overall"` |
| `labels` | `{:array, :map}` | tier ladder, ordered (class+min; highest tier first) |
| `default_class` | `:string` | floor tier (e.g. `"edge"`) |
| `input` | `Ecto.Enum [:last_user, :all]` | which text to classify |
| `timeout_ms` | `:integer` | enforce budget |

**`aliases`:** add `router_mode` (`Ecto.Enum [:shadow, :enforce], default: :shadow`);
keep `router`. **Migrate then drop** `router_config`: a data migration reads each
routed alias's existing `router_config`, seeds the singleton from the
(single, in practice) routed alias's config, and sets each alias's `router_mode` from
`router_config["mode"]`. Document that the homelab has one routed alias (`chat`).

`Airo.Config` gains: `get_routing_setting/0` (returns the row, creating a default if
absent), `update_routing_setting/1`, and `routing_config/0` (the parsed+cached map the
classifier consumes — mirrors today's `parse_config/1` output).

## 4. Tasks

### T1 — Schema + migration + context
- `routing_settings` singleton schema + changeset (backend enum; require `model` when
  `:ortex`, `classifier` when `:infinity`; non-empty `labels`; validate `score`).
- Migration: create table, seed one row from the existing routed alias's
  `router_config`; add `aliases.router_mode`, backfill from `router_config["mode"]`;
  then remove `aliases.router_config` (and the classifier keys it held).
- `Airo.Config`: `get_routing_setting/0`, `update_routing_setting/1` (writes →
  `:persistent_term` refresh + PubSub broadcast), `routing_config/0` (cached parse).

### T2 — Re-point the seam (no inference change)
- `Classifier.class_for/2`: source the config from `Config.routing_config/0` instead
  of `alias_.router_config`; keep `alias_` for logging context. `parse_config/1` moves
  to parsing the system setting (or is replaced by `routing_config/0`). `score/2`
  dispatch, `score_infinity/2`, `LocalClassifier.score/2`, `decide/2`: **untouched**.
- `Gateway.maybe_classify/4` (`gateway.ex:284`): `classifier_mode/1` reads
  `alias_.router_mode` (not `router_config["mode"]`); the `classify?/3` gate is unchanged.
- Non-regression: `:infinity` routing produces identical decisions/logs to S15.

### T3 — `/admin/routing` settings LiveView
New `AiroWeb.Admin.RoutingLive` (JobyKit-compliant: registered wrappers,
`data-component`, `attr :rest, :global`, `DesignManifest` entry, `mix joby_kit.lint`
green):
- **Engine** segmented control: **Local (Ortex) | Remote (Infinity)**.
- Local: `model` select (from the `fetch_model` manifest + holder load status — show
  ✓ loaded / ✗ unavailable) + a `score` weighting editor over the 6 dims (or "overall").
- Remote: `classifier` select (a `:classify`-capability alias).
- Shared: tier-ladder editor (ordered class+`min` rows), `default_class`, `input`,
  `timeout_ms`.
- **Prompt tester** (moved from the alias page): runs `Classifier`/`LocalClassifier`
  on a test prompt with the *current form* config, shows predicted tier + per-dim
  breakdown + latency — sends no traffic.
- Nav: add "Routing" to the admin nav.

### T4 — Simplify the alias form
- `alias_live.ex`: remove the classifier/labels/template block and
  `build_router_config/1`/`build_labels/1`. Replace with a **Routing** section: a
  `router` on/off toggle + a `router_mode` (`shadow|enforce`) select + a link to
  `/admin/routing` ("classifier configured in Routing settings"). This deletes the
  S15 clobber bug by construction.

### T5 — Tests
- `RoutingSetting` changeset (backend-branched requirements; bad config rejected).
- `Config.routing_config/0` cache: reflects updates; survives an absent row (default).
- Seam: `class_for/2` reads the system setting; `:infinity` decisions byte-for-byte
  vs S15; `:ortex` path unaffected (reuse the `:model`-tagged tests).
- Gateway: `router_mode: :enforce` applies, `:shadow` logs-only, `router: :none`
  unchanged; switching the system `backend` flips engine with no alias edit.
- LiveView: render `/admin/routing`, switch engine, save, prompt-test (stub/`:model`).

### T6 — Docs
- `DESIGN.md` §9: routing config is **system-level** (`/admin/routing`), aliases opt
  in via `router`/`router_mode`. Update the §15 checklist.
- `DESIGN-chat-routing.md` / `DESIGN-local-classifier.md`: note `router_config` is
  superseded by the system setting (pointer, not a rewrite).
- Sprint file: tick S16; append status-log line in `docs/sprints/STATUS.md`.

## 5. Rollout
1. Migrate (one routed alias today → seed singleton; backfill `router_mode`).
2. Operate from `/admin/routing`: switch **Remote ↔ Local** with one control; calibrate
   the ladder/weights with the built-in tester + the S15 shadow logs.
3. Enforce per alias via `router_mode` (no deploy). Engine and enforce are independent.

## 6. Definition of Done
Global DoD (`mix precommit` green; behavior tested; `docs/design/` + sprint file updated;
merged) **plus**: classifier config lives in one system row; `/admin/routing` switches
Local↔Remote + edits ladder/weights + tests a prompt; the alias form only toggles
`router`/`router_mode` (no clobber); migration carries existing config with no routing
behavior change; `mix joby_kit.lint` green.

## 7. Non-goals / deferred
- **Named/multiple classifier profiles** (per-alias selection) — singleton only.
- **Per-alias ladder/weight overrides** — the ladder is system-wide in v1.
- **The enforce cutover itself** — S16 ships the control (`router_mode`); flipping prod
  to enforce is an operational decision after calibration.
- **INT8 / fine-tune / ORT thread-pinning** — carried over from S15 §9, unrelated to
  this UI sprint.
