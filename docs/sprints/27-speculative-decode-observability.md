# Sprint 27 — Speculative-decode observability

> **Status: deliverables 1, 2, 3 and 5 implemented on branch
> `feat/spec-decode-observability`; deliverable 4 (a management-scoped key for
> helm) is unstarted and waiting on jody, because it is a prod credential
> change.** Not deployed. The investigation section below is the handoff from
> **2026-09-09**; every number in it was measured that day against the live
> `sparky:8081` slot and is reproducible with the commands quoted here.

> **Findings that change the premise** (read before planning anything):
> acceptance rate is **already available, unauthenticated, today** — the report
> that it was blocked confused two different `/metrics` endpoints. Per-request
> and in-stream acceptance is **genuinely unavailable** and was confirmed
> empirically, not assumed. The management-scope gap is real but is a
> *separate* item that would not have delivered acceptance rate.

> **Goal (one sentence):** make speculative-decode acceptance a first-class,
> per-deployment signal in Airo, so a harness can measure draft efficiency
> without scraping engines itself — and record honestly what is measurable
> per-arm versus per-request.

> **Why now.** helm's speculative benchmark reports `acceptance_reported: false`
> on every row and in the summary, and falls back to arm ratios as a proxy. The
> underlying counters exist and are open. The gap is plumbing and a scope, not a
> missing capability.

---

## The premise correction (do not re-litigate)

Two endpoints named `/metrics`, easily conflated. Only one of them was ever
going to answer this question, and it is not the gated one.

| Endpoint | Auth | Carries speculative counters? |
|---|---|---|
| **vLLM engine**, e.g. `http://192.168.68.93:8081/metrics` | **none** — HTTP 200 to anyone on the LAN | **Yes**, the full family |
| **Airo**, `/metrics` (`AiroWeb.MetricsController`) | `ClientKeyAuth, scope: :management` → 403 for an inference key | **No** — serving topology only (hosts, slots, deployments, aliases, usage) |

So the 403 helm saw was Airo's endpoint, and opening it would **not** have
produced an acceptance rate. Airo's `/metrics` has no engine-internal series
today; adding them is what this sprint is about.

## What's there now (verified 2026-09-09)

**The slot.** `sparky:8081` serves
`Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw:exl3` with speculation on:

```json
--speculative-config {"method":"dflash",
  "model":".../models--incoai--GLM-5.3-Flash-DFlash2/snapshots/dc77ff1c...",
  "num_speculative_tokens":7, "draft_tensor_parallel_size":2,
  "draft_sample_method":"probabilistic", "rejection_sample_method":"standard"}
```

**The counters the engine exposes** (`curl -s http://192.168.68.93:8081/metrics
| grep spec_decode`):

- `vllm:spec_decode_num_drafts_total`
- `vllm:spec_decode_num_draft_tokens_total`
- `vllm:spec_decode_num_accepted_tokens_total`
- `vllm:spec_decode_num_accepted_tokens_per_pos_total` (labelled `position`)
- plus `_created` gauges, which are timestamps, not values — ignore them.

**Cumulative reading at the time of measurement** (since engine start,
engine-wide, all requests from every caller):

| Signal | Value |
|---|---|
| drafts | 11,325 |
| draft tokens | 78,806 |
| accepted draft tokens | 29,746 |
| **acceptance rate** | **37.75%** |
| accepted per draft | 2.63 of ~7 drafted |
| mean tokens per decode step | 3.63 (1 verified + accepted) |

**Per draft position** — the decay that tells you whether
`num_speculative_tokens: 7` is earning its keep:

| position | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|---|
| accepted, % of drafts | 78.2 | 56.4 | 41.3 | 30.7 | 23.0 | 18.3 | 14.7 |

**Per-request acceptance does not exist on the wire.** Confirmed by probing the
live slot, not inferred:

- non-streaming response: top-level `metrics` key is present but **null**;
  `choices[0].token_ids` present but **null**
- streaming chunks: same two keys, same nulls; no per-chunk token array
- `usage` carries `prompt_tokens_details` only — no
  `completion_tokens_details`, so no `accepted_prediction_tokens` /
  `rejected_prediction_tokens` (the OpenAI Predicted-Outputs shape)

So `acceptance_reported: false` is **correct and honest for a single-request
row**, and should stay.

**The delta method works, and is the answer for per-arm measurement.** Scrape
the three counters before and after an arm and subtract. Proved end to end with
one 200-token request:

| | drafts | draft tokens | accepted |
|---|---|---|---|
| delta for one request | 64 | 448 | 135 |

That is **30.13% acceptance**, 2.11 accepted per draft, **3.11 tokens per decode
step**. The arithmetic closes: 64 steps × 3.11 ≈ 199 ≈ the 200 completion
tokens reported. No auth, no gate, no Airo change.

**Airo already scrapes this endpoint.** `Airo.Adapters.VLLM` has `metrics/1` →
`parse_metrics/1`, a general Prometheus line parser filtered by a **7-name
allowlist** (`@metric_names`, `lib/airo/adapters/vllm.ex:17`):
`num_requests_running`, `num_requests_waiting`, `kv_cache_usage_perc`,
`prompt_tokens_total`, `generation_tokens_total`, `num_preemptions_total`,
`request_success_total`. The parser already handles labels. Adding speculative
names is an allowlist edit plus a label-aware branch for `position`.

**The scope gap.** On prod, `helm-dev` and `helm-prod` are both `{inference}`.
Airo's `/metrics` and every `/v1/serving*` route require `:management`. This is
the pairing item noted against the helm power sprint — real, but label it
accurately: **helm needs a management key for Airo topology and Prometheus
data. It does not need one for acceptance rate.**

## A second premise correction, found while building (2026-09-09)

**Every agent-managed slot in the fleet is `adapter_type: :openai`, including
the vLLM ones.** Checked against both the dev database and prod: `forge:8081`,
`jobycorp:8081`, `macmini:8081`, `pvegpu:8081`, `sparky:8081` and
`sparky2:8081` are all `openai`. The engine is recorded on the **model**
(`models.engine`, `vllm` or `llama_cpp`), not on the provider.

So the obvious filter — scrape providers where `adapter_type == :vllm` — finds
**nothing in the fleet**. It would only ever match an external vLLM upstream,
of which there are none. `Airo.Engines.local_provider/1` is the mapping that
already exists for exactly this (the Model Shelf hit it first; its moduledoc
says so), and it is what the scrape filters on now.

## Design (as built)

1. **Widen the allowlist.** All four counters are in `@metric_names`. The
   per-position family keeps its `position` label, folded into
   `spec_decode_accepted_tokens_by_position` — a map keyed by **integer**
   position, so the curve orders without re-parsing label strings. It is the
   one name with no flat scalar: a flat key would hold whichever position was
   parsed last, which reads like a total and is not one.

2. **Derive, don't just relay.** A raw counter is not the signal. Expose a
   computed block per deployment so a consumer never divides wrong:

   ```
   speculative: {
     enabled: true,
     drafts: 11325, draft_tokens: 78806, accepted_tokens: 29746,
     acceptance_rate: 0.3775,
     accepted_per_draft: 2.63,
     tokens_per_step: 3.63,
     per_position: [0.782, 0.564, 0.413, 0.307, 0.230, 0.183, 0.147],
     cumulative_since: "engine_start",   # NOT per-request
     scraped_at: <timestamp>
   }
   ```

   `enabled: false` when the engine reports no speculative family, so absence
   reads as "not speculating", never as zero acceptance. Built as
   `Airo.Speculative`, with three states rather than two: `nil` means the slot
   was never scraped (option off, or not a vLLM engine), `enabled: false` means
   it was asked and does not speculate, and `enabled: true` with `nil` ratios
   means it speculates but has drafted nothing yet.

3. **Surface in `/v1/serving`, and as gauges in `/metrics`.** Both are
   management-scoped, which is the right home for engine internals — and is
   exactly why the scope item below has to land with it or the whole thing is
   invisible to helm. On `/v1/serving` it is opt-in behind `?speculative=1`,
   matching `?inventory=1`; on `/metrics` it is always on, because a scrape
   endpoint is what it is for.

   **`?speculative=1` defeats the `ETag`.** The counters climb on every request
   the engine serves, so the snapshot differs almost every call and the `304`
   path stops firing. Poll topology without it and ask for the numbers
   separately. Documented on the controller.

4. **Say "cumulative" in the field names and the docs.** Shipped as a
   `cumulative_since: "engine_start"` field in the payload, the first section of
   the `Airo.Speculative` moduledoc, and a paragraph on the `/metrics`
   controller. The single largest footgun here is a consumer reading
   `acceptance_rate` as belonging to its own request. It does not. It is
   engine-wide since start. The harness must delta.

5. **Do not put it on the inference path.** `/v1/serving` scrapes on demand;
   do not add a per-request engine call to the gateway hot path.

## Deliverables

1. **Done.** Speculative counters in `Airo.Adapters.VLLM`'s allowlist + parser,
   with the `position` label preserved. `metrics/1` is now public, so `Serving`
   can scrape without paying for the `/v1/models` call `runtime_info/1` makes.
2. **Done.** A derived `speculative` block per deployment in
   `Airo.Serving.snapshot/1`, behind `speculative: true`, `enabled: false` when
   absent. One `GET /metrics` per vLLM slot, concurrent, 4 s budget, ordered so
   a killed task is attributed to the right slot.
3. **Done.** `airo_spec_decode_*` gauges in `AiroWeb.MetricsController`:
   `enabled`, the three `_total` counters, `acceptance_rate`,
   `accepted_per_draft`, `tokens_per_step`, and `accepted_at_position_ratio`
   labelled by `position`.
4. **Open, sequenced after the deploy.** jody decided on 2026-09-09 to mint a
   new management-scoped key for helm rather than widen `helm-prod` /
   `helm-dev`, and to do it once this branch is on prod. Not done.
5. **Done.** A paragraph in the README's host-agent build-details section, and a
   note in `docs/design/DESIGN.md` §10 that engine-internal metrics are
   management-scoped by design.

## Tests

All written and passing; the full suite is green (636 tests, 3 doctests).

- **Parser** (`test/airo/adapters/vllm_test.exs`): a fixture of the real
  exposition from sparky yields the three counters and the per-position map,
  keeps no meaningless scalar for the per-position family, ignores `_created`
  timestamp lines, and yields no `spec_decode` keys at all for a slot serving
  without speculation.
- **Derivation** (`test/airo/speculative_test.exs`): acceptance rate,
  accepted-per-draft and tokens-per-step against the measured numbers above
  (37.75%, 2.63, 3.63), and the per-position curve (0.782 … 0.147) — these are
  the regression values. Also: a gap in the reported positions pads rather than
  shifting the curve, and a partial family degrades to `enabled: false` rather
  than to a wrong ratio.
- **Division guard**: zero drafts yields `nil` ratios, not `NaN`, not zero, and
  does not raise.
- **`/v1/serving`** (`test/airo_web/controllers/serving_controller_test.exs`):
  the block appears for a speculating deployment, reads `enabled: false` for a
  non-speculating one, is `null` when `?speculative=1` is absent (proved by
  leaving the engine unstubbed, so any scrape would raise), is `null` for a
  non-vLLM provider, degrades to a disabled block when the engine is
  unreachable, and still 403s for an inference key.
- **`/metrics`**: the gauge names, values and label sets above, including the
  `position` label; a non-speculating slot emits `enabled 0` and no rate series
  at all.

## Non-goals

- **Per-request acceptance.** Not on the wire (proved above). If it ever
  matters, it is a vLLM fork change, not an Airo one.
- Tuning `num_speculative_tokens`. The per-position curve is the data for that
  conversation; the decision is jody's and belongs to the engine payload, not
  to Airo.
- Changing helm. The delta method needs no harness change beyond scraping.
- Attributing acceptance to a client key or alias. The counters are engine-wide
  and cannot be split by caller.

## Risks

- **A consumer reads the cumulative rate as per-request.** The whole design
  hinges on naming and documenting this. Mitigation: `cumulative_since` in the
  payload, and say it in the field docs.
- **Counter reset on engine reload.** A slot reload zeroes the counters, so a
  delta spanning a reload goes negative. Any consumer differencing must treat a
  negative delta as "reset, discard the window".
- **Engine-version drift.** The metric names are vLLM-version specific; this
  fork is `0.25.2.dev0+g752a3a504`. A future image may rename them. The
  `enabled: false` fallback keeps that from reading as a regression.

## Acceptance

- `/v1/serving` on prod shows a `speculative` block for the GLM slot whose
  `acceptance_rate` matches a hand-computed ratio from the engine's own
  `/metrics` at the same moment, within rounding. **Verified against the live
  `sparky:8081` engine from the dev app on 2026-09-09**, not on prod (nothing
  was deployed). Scraping the engine at 15:48:40 UTC and deriving from it gave
  `acceptance_rate: 0.3721`, `accepted_per_draft: 2.59`, `tokens_per_step:
  3.59`, `per_position: [0.781, 0.561, 0.407, 0.3, 0.223, 0.177, 0.141]` — and
  the same 0.3721 / 2.59 hand-computed from the raw counters in the same
  scrape. The rate has drifted down from the 37.75% measured earlier that day
  because the counters keep climbing with new traffic; that drift is the point
  of `cumulative_since`.
- A non-speculating slot (any Qwen slot, `pvegpu:8081`) reports
  `enabled: false`. **Verified live**: `pvegpu:8081` exposes zero `spec_decode`
  lines, and its `model_name` label matches its Airo deployment exactly, so the
  `false` is a true negative rather than a name mismatch.
- Both slots were scraped through `Airo.Serving.snapshot(speculative: true)`
  despite being `adapter_type: :openai`, which is what proves the engine-based
  filter above.
- helm can read it with its key, and its rows carry a real rate instead of
  `acceptance_reported: false` — or, if the scope decision goes the other way,
  helm deltas the engine directly and the sprint drops deliverable 4.

## Open questions for jody

1. **Scope — decided by jody on 2026-09-09: mint a management key for helm,
   after the new Airo is deployed.** A new key rather than widening the existing
   `helm-prod` / `helm-dev`, and jody mints it. So the order is: deploy this
   branch to prod, then mint. Deliverable 4 stays open until both have
   happened; nothing on prod has been changed yet.
2. **Per-position in v1? — decided: shipped.** The parser work was the same
   either way once the `position` label had to be handled at all, and it is the
   only signal that answers "is `num_speculative_tokens: 7` too high". Exposed
   as an ordered array on `/v1/serving` and as a `position`-labelled gauge on
   `/metrics`.

## Session note (2026-09-09)

MemPal was unreachable from the investigation session (`ConnectionRefused` at
session start; the service itself was up and `claude mcp list` reported it
connected — the session's MCP client had bound to the failed state and does not
rebind without a restart). Nothing from that investigation reached memory, which
is why this file exists.

**Resolved.** MemPal reconnected in the build session later the same day, and
four facts were stored against the `airo` peer: the two-`/metrics` correction,
the delta method for per-arm acceptance, the absence of per-request acceptance
from this build's wire format, and the `adapter_type: :openai` finding above.
The build itself is recorded as an `episodic_event`.
