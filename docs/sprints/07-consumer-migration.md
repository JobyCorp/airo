# S7 — Consumer migration

**Status:** [x] done  
**Branch:** `sprint/07-consumer-migration`  

## Scope

- incogito: repoint `base_url` → Airo; send concrete model ids or single-candidate aliases
- orchester: delete resolver, repoint dispatch, translate strict pins → `route.binding`;
  keep Sink / agent loop / `:queued` Oban app-side
- **DoD extra:** both apps green against Airo
- _Complete: incogito and orchester now use Airo as the sole path to AI models._
