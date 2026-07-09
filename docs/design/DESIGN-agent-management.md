# Airo — Agent management: operator-driven control plane (S17)

> **Status: shipped (S17).** Historical sprint hand-off; describes implemented behavior.

Spec for **S17 — Agent control plane (operator-driven)**. Companion to
[airo_agent/DESIGN.md](../../../airo_agent/DESIGN.md) (Model 2: "Engine serves, agent
controls, Airo decides" — the control contract this consumes). This is the
implementation hand-off: self-contained, names exact files/functions, and fixes
the decisions so the build doesn't re-derive them.

> **Goal (one sentence):** turn the read-only `/agents` view into an
> operator-driven control plane — load / unload / swap the model resident in a
> host's slot from Airo, browse the host's inventory, and watch slot state
> update live — without coupling to deployments, routing, or placement policy.

> **Original motivation (pre-S17).** The Model 2 *spine* existed (the `Agent`
> entity, channel ingest, slot-Providers via `agent_id`, presence, the read-only
> `/agents` LiveView), but the control half was absent — nothing called the
> agent's `control_url`. S17 added the Airo-side client + UI + runtime state.

---

## 1. What already exists (the spine S17 builds on)

- **`Airo.Config.Agent`** — `host_id`, `control_url`, `version`, `enabled`,
  `last_seen_at`, `gpu`. One per host; slot-Providers link via `Provider.agent_id`.
- **`Airo.Agents.register/2`** — upserts the agent + each advertised slot as a
  managed `Provider` (`agent_id` set, `base_url` = the engine endpoint, adapter
  `:openai`).
- **`Airo.Agents.Ingest`** (`register/2`, `slot/2`, `host_down/1`) — channel-facing
  translation of pushes. **Today it (mis)infers the resident model from deployment
  health** — S17 replaces that (see §3).
- **`AiroWeb.AgentChannel`** — `register` / `slot` in; `terminate` → `host_down`.
  Already handles a server→agent `"resync"` message (agent re-pushes `register`).
- **`AiroWeb.Admin.AgentLive`** — read-only `/agents` (vitals, GPU meters,
  managed-slots table). Online/offline already live via a `Presence` subscription;
  GPU/slot data still on a 10s timer.
- **The agent's control API** (`airo_agent`, `AiroAgent.Api.Router`), bearer-authed
  with the shared token: `GET /health`, `GET /inventory`, `POST /inventory/refresh`,
  `GET /slots`, `GET /gpu`, `POST /load {model, slot, profile}`, `POST /unload {slot}`.
- **`config :airo, :agent_token`** (`runtime.exs`, from `AIRO_AGENT_TOKEN`) — already
  the channel join token; **reused verbatim as the control-API bearer**.

## 2. Fixed decisions (do not re-litigate)

- **Load is deployment-free.** Loading is *choosing which model occupies a slot* —
  an operational act on the engine, free-form against the host's **inventory**. It
  writes **no** `deployments` row. A `Deployment` is an orthogonal `(model,
  location)` routing binding; it may exist for a non-resident model, and a resident
  model may have no deployment. (Matches airo_agent/DESIGN.md: "which model is
  resident is runtime state the agent reports; which one *should* be is policy.")
- **Control = request; state = push.** Control flows by HTTP to `control_url`;
  state flows back over the channel. **`load`/`unload` return "accepted," they do
  not block** — the engine spawn/load is slow; completion arrives as a `slot` push
  (`loading` → `up` | `failed`). Airo never polls the agent.
- **Resident model is first-class slot runtime state**, sourced from the push, not
  inferred from deployments (§3).
- **Default profile for v1.** `/load`'s opaque `profile` blob is omitted; the agent
  applies its `default_profile`. Per-load / custom profile editing is a non-goal (§7).
- **Naive swap for v1.** Swap = load a different model into an occupied slot
  (implicit unload→load). No in-flight draining; the UI warns that a swap interrupts
  the resident model. Draining is a non-goal (§7).
- **No placement, no routing coupling.** Automatic "ensure the right model is
  resident before serving" (placement + eviction policy, the dispatch hook) is
  out of scope, not this sprint (§7).

## 3. The one schema/ingest change: resident slot state

The spine has nowhere to hold "slot S currently has model M (revision R), status
X." Because load is deployment-free, inferring it from deployment health is wrong.
The agent already sends it (`AiroAgent.SlotInfo`: `resident_model`, `revision`,
`status`; plus `slot` events with `status`/`reason`).

**Decision: hold it in ETS, mirroring `Airo.Health` — not a DB column.** Resident
state is volatile runtime signal, like health and presence; the design's contract
is that it **self-heals on reconnect** (the agent re-sends the full `register`,
absent ⇒ down). Putting it in the config DB would make `Provider` carry volatile
state and leave it stale after an Airo restart until re-register.

- **New `Airo.Agents.SlotState`** (ETS-backed, alongside `Airo.Runtime.Store` /
  `Airo.Health`): keyed by slot `provider_id` (or `host_id:port`), holding
  `{resident_model, revision, status, reason, updated_at}`. `put/2`, `get/1`,
  `for_agent/1`, `clear/1`.
- **`Ingest.register/2` + `Ingest.slot/2`** write `SlotState` from each slot's
  reported `resident_model`/`revision`/`status`. They **keep** marking deployment
  health from the slot push — that is the *only* health source for agent-managed
  providers (the prober skips any provider with an `agent_id`), so a deployment an
  operator binds to a slot still gets a routing signal. What moves is the
  **`/agents` UI**: it reads the resident model from `SlotState`, not by inferring
  it from deployment health (the old, now-wrong path, since loading writes no
  deployment row).
- **`Ingest.host_down/1`** clears the agent's slot states (absent ⇒ empty).
- **PubSub broadcast** on every change, on a **dedicated topic**
  (`Ingest.slots_topic/1 = "agent_slots:<host_id>"`, *not* the channel topic
  `agent:<host_id>` — broadcasting there would deliver to the `AgentChannel`
  process). `AgentLive` subscribes to both (presence + slots) and re-renders. A
  10s timer remains only as a fallback for GPU telemetry and roster drift.

## 4. The control client — `Airo.Agents.Control`

New module: the Airo→agent HTTP client, keyed on `agent_id`, bearer = `agent_token`.

- `inventory(agent)` → `GET {control_url}/inventory` — local models + provenance
  (`revision`). On-demand (UI opens the Load picker); not pushed.
- `slots(agent)` / `gpu(agent)` — `GET /slots` / `/gpu` (diagnostics / manual refresh).
- `load(agent, slot, model)` → `POST /load {model, slot}` (no `profile` ⇒ default).
  Returns `:accepted` on 2xx; the slot transitions arrive via the channel.
- `unload(agent, slot)` → `POST /unload {slot}`.
- `refresh_inventory(agent)` → `POST /inventory/refresh`.
- **Transport:** reuse `Airo.Transport` (Req/Finch) with a **short connect/recv
  timeout** (control calls are quick acks, not the load itself). Bearer from
  `Application.get_env(:airo, :agent_token)` when set.
- **Errors:** map unreachable / non-2xx / missing token to a tagged
  `{:error, reason}` the UI surfaces; never raise into the LiveView.

## 5. UI — `/agents/:id` becomes interactive

All within the JobyKit wrapper contract (`mix joby_kit.lint` green); reuse
`<.button>`, `<.icon_button>`, `<.table>`, `<.modal>`/existing patterns, the new
`meter`/`stat_tile`, `health_status`, `tag`.

- **Per-slot actions** in the managed-slots table: **Load** (opens a picker of
  `inventory` models → `Control.load`), **Unload**, **Swap** (Load into an occupied
  slot, with an interrupt warning). Disabled when the host is **offline** or a slot
  is `loading`.
- **Inventory panel** — `Control.inventory` results: model id, revision (provenance),
  size/family when present; a **Refresh inventory** action (`refresh_inventory`).
- **Resident model** shown from `SlotState` (the push), with `loading`/`up`/`down`
  status and the `failed` reason when present.
- **Resync** action (host-level) → triggers the agent's existing `"resync"`.
- **Live updates** via the §3 PubSub subscription: after Load, the slot goes
  `loading` → `up` and the resident model appears without a reload.

## 6. Security

The control API spawns processes on the GPU host → privileged. S17 carries the
existing posture: shared bearer (`agent_token`); when unset (dev/loopback) the
agent accepts any caller (already true for the socket). Controls are operator-only
(the admin surface) and disabled when the host is offline. No per-engine auth, no
new secrets.

## 7. Non-goals (explicit — deferred sprints)

- **Automatic placement / eviction on the serving path — out of scope.** The dispatch hook
  that ensures the right model is resident before serving a managed provider, plus
  slot-selection / VRAM-fit / what-to-evict policy. Open question in
  airo_agent/DESIGN.md; only safe to build on a proven manual client.
- **Provenance → Shelf (later).** Filling `Model.revision`/`version` from inventory
  and HF "update available" polling — belongs with the Model Shelf (S12) lineage.
- **Profile editing.** Custom/per-load launch profiles (ctx, KV-quant, `--jinja`,
  MTP flags). v1 uses the agent default.
- **Drain-on-swap.** Graceful in-flight drain before unload/swap.
- **Model pull / acquisition.** HF download remains out of band.

## 8. Definition of Done (sprint-specific)

- With a live agent: an operator **loads** a model into a slot from `/agents/:id`,
  the slot goes `loading` → `up` **live**, the resident model + revision show; a
  **swap** replaces it; an **unload** frees it (`empty`/`down`).
- Resident state comes from the push (`SlotState`), independent of deployments;
  loading creates no `deployments` row.
- `Airo.Agents.Control` unit-tested against a **stubbed Req plug** (per the sprint
  rule — not a live agent): `load`/`unload`/`inventory`/error mapping.
- `Ingest` writes/clears `SlotState` and broadcasts; an offline host disables controls.
- `mix precommit` + `mix joby_kit.lint` green; `docs/design/` + sprint file updated.
