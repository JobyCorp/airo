# S0 — Foundations & config plane

**Status:** [x] done  
**Branch:** `sprint/00-foundations-config-plane`  

## Scope

No provider calls yet; just the schema both apps converge onto.
- Cloak vault + `Airo.Encrypted.Binary` Ecto type
- Migrations + schemas + changesets: `Provider`, `Deployment`, `Alias`,
  `ClientKey`, `Secret`, `UsageRecord` (DESIGN §8)
- `Airo.Config` context(s); dev seeds for one local provider
- **DoD extra:** migrations run clean; changeset tests cover required fields + enums
