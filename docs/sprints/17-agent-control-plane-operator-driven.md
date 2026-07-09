# S17 — Agent control plane (operator-driven)

**Status:** [x] done  
**Branch:** `sprint/17-agent-control-plane-operator-driven`  
**Design:** [DESIGN-agent-management.md](../design/DESIGN-agent-management.md)

## Scope

Builds on the Model 2
spine (interim: `Agent` entity, channel ingest, slot-Providers, `/agents` read-only).
Turn the read-only `/agents` view into operator-driven control — load / unload / swap
the model resident in a host's slot from Airo — with **no** deployment, routing, or
placement coupling.
- **Resident slot state, first-class:** new `Airo.Agents.SlotState` (ETS, mirrors
  `Airo.Health`) holding `resident_model`/`revision`/`status`/`reason` from the
  push; `Ingest.register`/`slot` write it (and **drop** the deployment-health
  inference of the resident model), `host_down` clears it, every change broadcasts
  on PubSub
- **Control client** `Airo.Agents.Control` (HTTP → `control_url`, bearer =
  `agent_token`, short timeouts, tagged errors): `inventory/1`, `slots/1`, `gpu/1`,
  `load/3` (default profile), `unload/2`, `refresh_inventory/1`. **Control =
  request; state = push** — `load`/`unload` return "accepted," completion arrives as
  a `slot` push (`loading`→`up`|`failed`)
- **`/agents/:id` interactive:** per-slot Load (inventory picker) / Unload / Swap
  (interrupt warning) / Resync; inventory panel with provenance (revision); resident
  model from `SlotState`; controls disabled when the host is offline; live updates
  via the PubSub subscription (replaces the slot/GPU 10s timer)
- **Fixed decisions:** load is deployment-free; default profile only; naive swap (no
  drain); placement-on-dispatch is out of scope, provenance→Shelf is later (DESIGN §2, §7)
- **DoD extra:** with a live agent, an operator loads→swaps→unloads a slot and the
  resident model/revision/status update live with no deployment row written;
  `Airo.Agents.Control` tested against a stubbed Req plug (not a live agent)
- _Complete: `Airo.Agents.SlotState` (ETS) + `Ingest` write/clear/broadcast on a
  dedicated `agent_slots:<host_id>` topic; `Airo.Agents.Control` client (9 tests vs
  stubbed Req); `/agents/:id` Load/Swap/Unload/Resync + inventory picker, resident
  state from the push, offline guards. precommit + joby_kit.lint green (329 tests).
  Push→live-update verified end-to-end; happy-path load pending a reachable host._
