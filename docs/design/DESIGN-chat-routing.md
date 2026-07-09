# Airo — Classification-driven chat routing (S13)

> **Status: shipped (S13).** Historical sprint hand-off; describes implemented behavior. Config location superseded by S16 — see DESIGN-routing-settings.md for the current schema.

Spec for **S13 — Routed `chat` alias**. Companion to [DESIGN.md](./DESIGN.md) §9
(Routing) and §5.1 (the opt-in `route` object). This is the implementation
hand-off: it is self-contained, names exact files/functions, and fixes the
decisions so the work doesn't need to re-derive them.

> **Goal (one sentence):** add a `chat` alias that classifies the incoming
> prompt and routes it to the right model *tier* by computing `route.class`,
> reusing the entire existing candidate/health/failover machinery — shipped in
> **shadow mode** (logs its decision without acting on it) so thresholds can be
> calibrated on real traffic before it routes anything.

> **Superseded (S16).** The per-alias `router_config` map described below now lives
> in **one system-level setting** (`Airo.Config.RoutingSetting`, edited at
> `/admin/routing`); aliases only carry `router` + `router_mode`. The mechanics
> (NLI pairs, thresholds, fail-open, shadow/enforce) are unchanged — only *where the
> config lives* moved. See [DESIGN-routing-settings.md](./DESIGN-routing-settings.md).

---

## 1. Why this is small

Three pieces already exist; the classifier only has to feed them:

1. **Tier vocabulary** — `Airo.Config.Deployment.class` is a typed enum
   `[:edge, :standard, :deep, :cloud]` (`lib/airo/config/deployment.ex:20`).
2. **Per-request tier selection** — `Airo.Routing` already filters candidates by
   `route["class"]` (`filter_class/2`, `lib/airo/routing.ex:123–126`), and `route`
   is stripped as a gateway-only key before dispatch (`lib/airo/gateway/params.ex:26`).
3. **The `:classify` dispatch path is already wired *and tested*.** `classify_controller.ex`
   resolves a `:classify` alias and runs it through `Gateway.resolve/3` + `run/1`;
   `test/airo/adapters/infinity_test.exs` stubs the `/classify` plug via
   `ctx.opts[:req_options]`, and `classify_controller_test.exs` builds exactly the
   `capabilities: [:classify]` deployment + `capability: :classify` alias we need.
   The T0 spike below was run against the *live* endpoint through this same path; the
   T1/T2 tests should copy these stubs verbatim.

So the **whole job is to compute `route["class"]`** for one alias. Strategy
ordering, health preference, failover, the `fallback` chain, usage records, and
streaming all already work and need **zero** changes.

There is also a safe-default property we lean on: when `route["class"]` is
absent, `filter_class` passes *all* candidates through by strategy/health
(`lib/airo/routing.ex:123–126`). So a routed alias whose classifier is disabled,
in shadow mode, or failing simply behaves as an ordinary priority alias.

## 2. Tier mapping (fixed)

Reuse the existing `class` enum as the tier key — do **not** invent a new field:

| `class`      | Backend                          | When |
|--------------|----------------------------------|------|
| `:edge`      | 35b fast / no-think (LM Studio)  | default: simple Q&A, tool calls |
| `:deep`      | 122b thinking (Spark vLLM)       | multi-step reasoning, math, code |
| `:cloud`     | Claude (Anthropic adapter)       | multi-file / long-horizon coding |
| `:standard`  | spare mid-tier                   | unused for v1 |

> **v1 scope = `:edge` vs `:deep` (fast vs slow).** Cloud is deferred — there's no
> `:cloud` deployment and no way to test one here — so v1 classifies the single
> decision that matters operationally: *is this prompt worth the slow thinking model?*
> The tier *vocabulary* keeps `:cloud`/`:standard` for later, but the shipped
> `router_config` (§3) carries **one `:deep` label** and defaults everything else to
> `:edge`. Live class tags now match this table for edge/deep (the 35b LM Studio model
> is `:edge`, fast/no-think); `:deep` is the single Spark vLLM thinking model. Full
> inventory + the alias rows to create are in §11; calibration in §10.

## 3. Data-model change

Add two columns to `aliases` (non-breaking — existing rows default to `:none`
and behave exactly as today):

- `router` — `Ecto.Enum, values: [:none, :classify], default: :none`
- `router_config` — `:map, default: %{}`

`router_config` (consulted only when `router == :classify`):

```jsonc
{
  "mode":        "shadow",                 // "shadow" = log only · "enforce" = apply route.class
  "classifier":  "prompt-class",           // alias name (capability :classify) to call
  "input":       "last_user",              // "last_user" | "all" — which text to classify
  "hypothesis_template": "This request requires {}.",   // airo renders per label → NLI hypothesis (option B, §10)
  "labels": [                              // single :deep label for v1; mechanism supports more, highest-tier-first
    {"label": "multi-step reasoning, math, or analysis", "class": "deep", "min": 0.5}
  ],
  "default_class": "edge",                 // anything that doesn't cross `min` → :edge, the fast default (NOT on error/timeout — §4)
  "timeout_ms":   200                      // hard budget (live p50 ≈ 45ms, §10); on exceed => fail-open: no class filter (§4)
}
```

> **Mechanics (validated live, §10).** `hypothesis_template` + each `labels[].label`
> are combined by airo into the NLI hypothesis (`render(template, label)`); the
> premise is the extracted `input` text. Infinity scores the pair's **`entailment`**
> probability per label and airo compares that to `min` — Infinity does **not** do
> zero-shot orchestration itself (option **B**). All labels score in one batched call.

## 4. Fixed decisions (do not re-litigate)

- **Tier key = `Deployment.class`.** Already typed, already filtered on. See §2.
- **Classifier provides a *default* for `route.class`; the caller still wins.**
  If the request already carries `route.class` or `route.binding`, skip
  classification entirely. "Caller's desired model" stays the escape hatch.
- **Hard filter + fallback chain for cross-tier safety.** `filter_class` is a
  hard filter, so a chosen tier that is down has no *in-tier* failover; set the
  alias `fallback` (e.g. `["chat-standard"]`) for cross-tier resilience. A
  "soft prefer" that reorders instead of filtering is a **non-goal** for S13
  (see §9).
- **Fail-open, always — but distinguish *unknown* from *low-confidence*.** A
  classifier **error / timeout / missing-classifier** ⇒ apply **no class filter**
  (the full priority + failover set, i.e. today's unrouted behavior). Only the
  **nothing-crossed-a-threshold** case uses `default_class` — that's a genuine
  low-confidence signal that the prompt is edge-tier. *Rationale:* `filter_class`
  is a **hard** filter, so collapsing a timeout to `default_class: "edge"` would
  silently shrink chat to the edge tier precisely when the system is degraded. The
  router being down must never fail a request **and** must never quietly shrink
  failover. (This refines the original "error ⇒ default_class" decision after the
  ground-truth review.)
- **Shadow adds no caller latency.** In `mode: "shadow"` the classifier runs
  **detached** (supervised `Task`, logging from inside) so the chat request is not
  blocked on the round-trip. The synchronous bounded-`Task` (budget `timeout_ms`)
  is used only in `mode: "enforce"`, where the result must gate routing. (Live p50
  ≈ 45 ms over the homelab LAN, so enforce's 200 ms budget has ~4× headroom — §10.)
- **Shadow first.** Ship `mode: "shadow"`. Flipping to `"enforce"` is an
  operational `router_config` edit, not a code change.

---

## 5. Tasks

Order matters; T0 gates T2.

### T0 — Spike: confirm the Infinity `/classify` zero-shot contract — ✅ RESOLVED (verdict: **B**)
Validated live (2026-06-18) against provider `Infinity` →
`https://infinity.local.joby.gg`, deployment 13
`MoritzLaurer/deberta-v3-large-zeroshot-v2.0`, probed through the real
`Airo.Adapters.Infinity.classify/2`. Full request/response evidence + threshold
validation + latency in **§10**.

**Verdict: B.** Infinity runs only the model's fixed NLI head — it **ignores**
`candidate_labels`/`hypothesis_template` (passthrough no-ops; identical responses
with and without them). So airo builds the NLI pair itself
(`input = premise <> " " <> render(template, label)`) and reads the `entailment`
score (branch **B** of `score_labels/4`). Two findings that shape T2:

- **Batched:** `input` is a list and `data` returns one row per element, so the
  whole label set scores in **one** call (no per-label loop).
- **No `infinity.ex` change** — the adapter's near-passthrough `classify/2`
  (`lib/airo/adapters/infinity.ex:40–45`) already carries it.

### T1 — Schema + migration
- `mix ecto.gen.migration add_router_to_aliases`; add `router` (string, default
  `"none"`, not null) and `router_config` (map/jsonb, default `%{}`, not null).
- `lib/airo/config/alias.ex`: add both fields (mirror the `strategy` enum + the
  `default_params` map), add to the `cast/3` list. Light validation only: valid
  `router` enum; when `router == :classify`, require `router_config` to be a
  non-empty map (deep validation lives in the classifier, not the changeset).
- **Tests** (`test/airo/config/alias_test.exs`): defaults to `:none`/`%{}`;
  accepts `:classify` + a config map; rejects an unknown `router`. Note the
  changeset uses **`capabilities:` (plural list)** for deployments — `seeds.exs`
  still shows the stale singular `capability:` (in fact `seeds.exs:38` would *raise*:
  `capability:` isn't cast and `validate_required([:capabilities])` rejects it — see
  §11); follow `alias_test.exs`.

### T2 — `Airo.Routing.Classifier`
New module `lib/airo/routing/classifier.ex`. Single public function:

```elixir
@spec class_for(Airo.Config.Alias.t(), map()) ::
        {:ok, String.t(), map()} | :skip | {:error, term()}
```

**Return contract:** `{:ok, class, scores}` decided (`scores = %{class => entailment}`,
surfaced for the T5 log) · `:skip` = nothing classifiable (no extractable user text) ·
`{:error, _}` = config/upstream/timeout failure. `class_for/2` is **total** — a
function-level `rescue` turns any DB/resolve/decode explosion into `{:error, _}`, so
enforce (which runs it in the request process) can never raise into a chat request. The
hook (T3) treats `:skip` and `{:error, _}` identically (leave `route` untouched) but
logs them distinctly.

Steps:
1. Parse `alias_.router_config`. (Return `{:error, :bad_config}` if `:classify`
   but unusable — the hook treats it as fail-open.)
2. Extract text from `params` per `"input"` (`last_user` = last `user` message's
   text content; drop non-text/image parts; `all` = concatenate the turns). If the
   result is empty/whitespace, return `:skip`.
3. Resolve the classifier deployment: `Config.get_alias_by_name(classifier)`
   (**nil ⇒ `{:error, :bad_config}`**) → `Airo.Routing.candidates(alias, %{}, :classify)`
   (**`{:error, _}` / `[]` ⇒ `{:error, _}`**) → head candidate. Build the call the
   way `Gateway.build_attempts/4` does for one candidate:
   `Airo.Registry.fetch(provider.adapter_type)` →
   `Airo.Adapter.Context.new(provider, deployment: deployment)` →
   `adapter.classify(body, ctx)`. This deliberately bypasses `Gateway.resolve/3` +
   `run/1` (and the auth/ClientKey layer): it's an internal call, and we
   **intentionally forgo** per-candidate failover, health marking, and a
   `UsageRecord` for the classifier hop — fail-open (step 6) is the safety net and we
   don't want classifier traffic polluting usage. **Recursion-safe by construction:**
   this path calls `Routing.candidates` directly, never `alias_target/3`, so a
   misconfigured `router: :classify` on the classifier alias can't re-enter the
   classifier.
4. `score_labels/4` → `%{class => entailment}`, **branch B** (per §10): build
   `input = premise <> " " <> render(hypothesis_template, label)` for every label;
   send them as **one** batched `%{"input" => [...]}` call (Infinity returns one row
   per input, same order); read each label's **`entailment`** score by *label lookup*
   within its row (order inside a row is **not** positional). `default_class` is not
   a label and is not scored.
5. Decide: walk `labels` in order, return the first `class` whose score ≥ `min`;
   else `default_class`.
6. Wrap the upstream call in a `Task` bounded by `timeout_ms` (`Task.async` +
   `Task.yield`/`Task.shutdown`); on timeout/error return `{:error, _}`. (In *shadow*
   it's the hook, not this function, that runs `class_for` detached — see §4 + T3.)

- **Tests:** stub the Infinity `/classify` HTTP the way
  `test/airo/adapters/infinity_test.exs` does (test plug via `ctx.opts[:req_options]`;
  reuse its `Req.Test` setup and the `capabilities: [:classify]` deployment from
  `classify_controller_test.exs`). Cover: correct class per thresholds/order, incl. a
  prompt that crosses **two** thresholds → highest tier wins (the live multi-file-code
  case in §10 does exactly this); `default_class` when nothing crosses; `:skip` on
  empty input; `{:error, _}` on upstream error, on timeout, and on a missing classifier
  alias; clean parse of the real response shape (use the §10 JSON as a fixture).

### T3 — Gateway hook
In `lib/airo/gateway.ex`, `alias_target/3` (`:260–273`) currently builds `route`
from `params["route"]`. Insert one line and a helper:

```elixir
route = if is_map(params["route"]), do: params["route"], else: %{}
route = maybe_classify(alias_, params, route, resource)
```

`maybe_classify/4` runs the classifier **only** when all hold, else returns
`route` unchanged:
- `alias_.router == :classify`
- `resource in [:chat, :vision]`
- `is_nil(route["class"]) and is_nil(route["binding"])`  *(caller wins)*

On `Classifier.class_for/2`, by `mode`:
- **enforce** + `{:ok, class}` → `Map.put(route, "class", class)`.
- **enforce** + `:skip` → `route` unchanged. **enforce** + `{:error, _}` → `route`
  unchanged (= **no class filter**, per §4 — a classifier failure must not narrow
  failover; `default_class` is applied *inside* the classifier only for the
  no-threshold-crossed case, never for errors).
- **shadow** (any `{:ok, _}` / `:skip` / `{:error, _}`) → never mutates `route`; run
  `class_for` **detached** (supervised `Task`) so serving isn't blocked, and emit the
  T5 log from inside the task.

Keep `maybe_classify` private to the gateway. In *enforce* it runs synchronously
(the class must gate routing before `Routing.candidates`); in *shadow* it spawns the
detached task and returns `route` immediately.

> **Forward caveat (caller-wins completeness).** Today `route` comes *only* from
> `params["route"]` (`gateway.ex:261`, `vision.ex:16`); the `x-route-class` header in
> DESIGN §5.1 is documented but **not implemented**, so the
> `is_nil(route["class"])` check is complete. If those headers are ever wired, they
> must be merged into `route` *before* `maybe_classify`, or header-callers lose
> precedence over the classifier.

- **Tests** (`test/airo/gateway_test.exs` or sibling): enforce + stubbed classifier
  → candidates filtered to the predicted class; **enforce + stubbed classifier error
  → no class filter** (full candidate set — non-regression); shadow → serves the
  priority head, `route` unchanged, request not blocked, log emitted; **streaming**
  (`:stream` capability, whose `resource` resolves to `:chat`/`:vision`) classifies
  too; explicit `route.class`/`route.binding` → classifier not called; `router: :none`
  alias → byte-for-byte unchanged behavior.

### T4 — Config / operator runbook
Committed code stays env-agnostic (the repo `seeds.exs` is dev-only). Deliver an
**operator runbook** section in this doc (§11) + optional dev-seed additions:
- A `prompt-class` alias (`capability: :classify`, `:priority`) → one candidate:
  the Infinity deberta deployment. **Reuse if it already exists** (the classify
  endpoint may already be wired).
- The chat deployments tagged `:edge`/`:deep` (cloud deferred — §11).
- A `chat` alias: `capability: :chat`, `strategy: :priority`, candidates =
  `[edge (priority 0), deep (priority 1)]` (cloud deferred — §11),
  `fallback: ["chat-standard"]`, `router: :classify`, `router_config:` the §3
  example with `mode: "shadow"`.

### T5 — Observability
Emit a structured log event `gateway.route.classified` (match the
`gateway.attempt.*` style in `gateway.ex`) with: `alias`, `predicted_class`,
`scores`, `mode`, `applied` (bool), `latency_ms`, and the S11 trace id. Logs are
the shadow-mode dataset for threshold calibration. *(Persisting the predicted
class on `UsageRecord` is a non-goal — see §9.)*

### T6 — Docs
- `DESIGN.md` §9: add a subsection **"Classification-driven routing (routed
  aliases)"** describing `router`/`router_config`, the compute-`route.class`
  mechanic, caller-precedence, and fail-open. Add a one-line pointer in §5.1
  (the `route` object now has a server-side default source) and an entry in §15.
- Sprint file: tick S13; append status-log line in `docs/sprints/STATUS.md`.

---

## 6. Rollout

1. **Shadow** (this sprint): `chat` serves by priority (edge first) and logs the
   predicted class on every request via a **detached** classifier call (no added
   caller latency — §4). No behavior change for callers.
2. **Calibrate**: read `gateway.route.classified` logs; tune `labels`/`min`
   against what the tiers actually handled well.
3. **Enforce**: edit `router_config.mode` → `"enforce"` (admin/DB; no deploy).
   `route.class` is now applied; cross-tier failover via `fallback`.

## 7. Definition of Done (this sprint)

Global DoD from `docs/sprints/README.md` (`mix precommit` green — compile
`--warnings-as-errors`, `deps.unlock --unused`, `format`, `test`; new behavior
tested against a stubbed Req plug, not live; `docs/design/` updated; sprint file
ticked; branch merged to `main`) **plus**:
- T0 verdict recorded in §10; classifier parses the real response shape.
- Routed alias in **enforce** filters to the predicted class; in **shadow**
  serves the priority head and logs; both covered by tests.
- A `router: :none` alias is byte-for-byte unchanged (non-regression test).

## 8. Test plan summary
Classifier unit (thresholds/order/default/fail-open/timeout, stubbed Req) ·
gateway integration (enforce filters, shadow logs-only, caller-wins, none-alias
regression) · schema changeset (defaults, enum, config required when
`:classify`).

## 9. Non-goals / open questions (deferred)
- **Soft-prefer reordering** (prefer a tier but keep the rest as failover without
  a hard filter) — a small `Airo.Routing` enhancement; revisit if hard-filter +
  `fallback` proves too blunt.
- **Predicted class on `UsageRecord`** — add a column later if log-based
  calibration is insufficient.
- **Multi-turn / agentic-context signal** — classification reads the last turn
  only (DESIGN §9 already notes routers are first-turn-trained); the
  "long-horizon coding → cloud" decision may later want session context, not just
  prompt text.
- **Result caching** by prompt hash (short TTL) to cut the per-request classifier
  round-trip — optimization, not v1.

## 10. T0 verdict — **B** (validated live 2026-06-18)

**Endpoint.** Provider `Infinity` (id 1) → `https://infinity.local.joby.gg`,
deployment 13 `MoritzLaurer/deberta-v3-large-zeroshot-v2.0`
(`capabilities: [:classify]`). Probed through the real adapter
`Airo.Adapters.Infinity.classify/2`.

**Verdict: B — Infinity runs only the model's fixed NLI head.** Sending
`candidate_labels` + `hypothesis_template` returned a **byte-identical** response to
sending neither (same scores, same `usage`) — they are passthrough no-ops. Infinity
does **no** zero-shot orchestration.

**So airo constructs the NLI pair itself**, one input string per label, and reads the
`entailment` probability:

- Input: `input = premise <> " " <> hypothesis`, `hypothesis = render(template, label)`.
  Plain-space join works; a separator (`[SEP]`, `</s></s>`, newline) is within noise.
  The premise **must** be present — hypothesis-only gives no signal (entailment ≈ 0.05
  either way).
- **Batched:** `input` is a list; `data` returns one row per element — score the whole
  label set in **one** call.
- Read `entailment` **by label lookup** — order within a row is not stable
  (`[entailment, not_entailment]` and `[not_entailment, entailment]` both observed).
- **No `infinity.ex` change** — the existing `classify/2` passthrough carries it.

**Request JSON** (airo passes `input` only; the adapter injects `model`):

```json
{ "model": "MoritzLaurer/deberta-v3-large-zeroshot-v2.0",
  "input": [
    "Refactor the auth module across these three files... This request requires editing or debugging code across multiple files.",
    "Refactor the auth module across these three files... This request requires multi-step reasoning, math, or analysis."
  ] }
```

**Response JSON** (one inner list per input):

```json
{ "object": "classify",
  "data": [
    [ {"label": "entailment", "score": 0.996}, {"label": "not_entailment", "score": 0.004} ],
    [ {"label": "entailment", "score": 0.809}, {"label": "not_entailment", "score": 0.191} ]
  ],
  "usage": {"prompt_tokens": 94, "total_tokens": 94} }
```

**`score_labels/4` branch B** (pseudocode):

```elixir
inputs = Enum.map(labels, &(premise <> " " <> render(template, &1["label"])))
{:ok, %{"data" => rows}} = adapter.classify(%{"input" => inputs}, ctx)
labels
|> Enum.zip(rows)
|> Map.new(fn {l, row} ->
  e = Enum.find(row, &(&1["label"] == "entailment"))["score"]
  {l["class"], e}
end)
```

**Threshold validation (v1 = edge vs deep)** — the §3 config's single `:deep` label
("multi-step reasoning, math, or analysis"), live `entailment`:

| prompt                                            | deep entailment | → routed (min 0.5) |
|---------------------------------------------------|-----------------|--------------------|
| "Thanks, that's really helpful!"                  | 0.009           | `edge`             |
| "Summarize this short email in one sentence…"     | 0.022           | `edge`             |
| "What's the capital of France?"                   | 0.08            | `edge`             |
| "Write a Python function that reverses a string." | 0.134           | `edge`             |
| "Refactor the auth module across three files…"    | 0.881           | `deep`             |
| train/overtake word problem ("show your work")    | 0.955           | `deep`             |
| "Compare optimistic vs pessimistic locking…"      | 0.965           | `deep`             |

The edge cluster tops out at **0.134**, the deep cluster bottoms at **0.881** — a
~0.75 gap, so `min` isn't delicate (anything 0.2–0.85 separates these); `min: 0.5`
centers it. Simple code correctly stays on the *fast* edge tier (0.134); an alternate
label that appended "coding" dragged it to 0.529 (ambiguous) for no gain — rejected.

> **3-way is viable later.** With a second `:cloud` label ("editing or debugging code
> across multiple files"), the same model scored the multi-file-debug prompt **cloud
> 0.996 > deep 0.809** — cleanly above a 0.60 cloud threshold. So adding a cloud tier is
> a `router_config.labels` edit once a `:cloud` deployment exists; the "highest tier
> first, first over `min` wins" ordering then becomes load-bearing (validate it then).

**Latency.** p50 ≈ **45 ms** for a batched call (44–47 ms over 5 samples, homelab LAN)
— the §3 `timeout_ms: 200` budget has ~4× headroom.

## 11. Operator runbook (live inventory 2026-06-18)

**Exists today** (homelab DB — confirmed by query, no `mix run` needed):

- **Classifier deployment** ✅ — deployment **13** `MoritzLaurer/deberta-v3-large-zeroshot-v2.0`,
  `capabilities: [:classify]`, provider **Infinity** (id 1, `https://infinity.local.joby.gg`).
  Reuse as-is.
- **Chat deployments** (id · model · class · provider) — *35b re-tagged `:edge` 2026-06-18*:
  - `:edge` — **6** `qwen3.6-35b-…` (lmstudio; fast/no-think) · **9** `qwen3.5-9b` (vllm) · **12** `moondream` (ollama; vision-first)
  - `:deep` — **15** `qwen35-nvfp4` (vllm-spark) — **single candidate** (no in-tier failover; see Notes)
  - `:standard` — **14** `unsloth/Qwen3-Coder-30B…` (unsloth; unused by v1)

**Must be created — there are *no* aliases in the DB at all:**

- **`prompt-class`** — `capability: :classify`, `strategy: :priority`, one candidate →
  deployment 13. (The classify *endpoint* is wired and tested; only the alias is missing.)
- **`chat-standard`** — the `fallback` target. `capability: :chat`, candidate(s) of your
  choice (e.g. deployment 14, the `:standard` coder).
- **`chat`** — `capability: :chat`, `strategy: :priority`, candidates
  `[9 (edge) p0, 6 (edge) p1, 15 (deep) p2]`, `fallback: ["chat-standard"]`,
  `router: :classify`, `router_config:` the §3 example (`mode: "shadow"`). (Add
  moondream 12 only if you want a vision/chat fallback — it's a tiny model.)

**Notes:**

- **Cloud is deferred — not a blocker.** v1 is edge-vs-deep; the §3 config carries no
  `:cloud` label, so nothing predicts or routes cloud. Adding it later = an Anthropic
  provider + a `class: :cloud` deployment + one label in `router_config` (the adapter
  already implements `chat/2` + `stream/4`). 3-way separation is already evidenced in §10.
- **`:deep` is a single deployment (15).** A `deep`-predicted request has **no in-tier
  failover** — if 15 is down it falls through to `fallback: ["chat-standard"]`, so make
  sure `chat-standard` resolves to something healthy. (This is the §4 hard-filter caveat
  made concrete.)
- **`seeds.exs` is broken, not just stale** (re T1): `priv/repo/seeds.exs:38` passes
  `capability: :chat` to `create_deployment`, which the Deployment changeset doesn't cast
  (it casts `:capabilities`) and `validate_required([:capabilities])` rejects — a fresh
  `mix run priv/repo/seeds.exs` raises at the deployment step. Wire the rows above via the
  admin UI (`/admin/aliases`, `/admin/providers`) instead, or fix seeds.
