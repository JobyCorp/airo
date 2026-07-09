# S6 — Observability & config UI

**Status:** [x] done  
**Branch:** `sprint/06-observability-config-ui`  

## Scope

- Async `UsageRecord` writes + cost from `Deployment` pricing
- LiveView admin (JobyKit) for Providers/Deployments/Aliases/Keys + usage view
- OpenAPI spec via `open_api_spex`; Oban prune worker for `UsageRecord`
- **DoD extra:** admin CRUD works; spec served at `/openapi`; usage recorded
