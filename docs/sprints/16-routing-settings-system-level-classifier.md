# S16 — Routing settings (system-level classifier)

**Status:** [x] done  
**Branch:** `sprint/16-routing-settings-system-level-classifier`  
**Design:** [DESIGN-routing-settings.md](../design/DESIGN-routing-settings.md)

## Scope

Depends on S13 (classifier seam) + S15 (`:ortex` backend). Lift the classifier
config out of `aliases.router_config` into **one system-level "Routing"
setting**, with an `/admin/routing` UI to choose the engine (**local Ortex |
remote Infinity**) + model, the score weighting, and the tier ladder, and to
test a prompt — so a routed alias only **opts in** (`router` + `router_mode`)
and inherits the system classifier. Also retires the S15 alias-form clobber bug.
- **Schema/migration:** `routing_settings` singleton (`backend`, `classifier`,
  `model`, `score`, `labels` ladder, `default_class`, `input`, `timeout_ms`);
  add `aliases.router_mode` (`:shadow|:enforce`); migrate then drop
  `aliases.router_config`; `Config.routing_config/0` cached in `:persistent_term`
- **Seam re-point (no inference change):** `Classifier.class_for/2` reads the
  system setting; `Gateway` mode reads `alias_.router_mode`; `score/2` dispatch,
  both backends, and `decide/2` untouched; `:infinity` decisions unchanged
- **`/admin/routing` LiveView:** Local|Remote engine control, model/classifier
  pick (+ holder load status), weighting + ladder editors, moved prompt-tester;
  JobyKit-compliant (`mix joby_kit.lint` green)
- **Alias form:** reduce to a `router` toggle + `router_mode` select + a link to
  Routing settings (removes `build_router_config/1` and the clobber)
- **DoD:** config in one system row; engine switch Local↔Remote in one control;
  alias form can't clobber; migration carries existing config with no behavior
  change; precommit + joby_kit.lint green
