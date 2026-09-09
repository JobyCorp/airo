# Sprint 27 — Speculative-decode observability

> **Status: planned.** Nothing implemented. This file is the handoff from the
> investigation session of **2026-09-09**; every number below was measured that
> day against the live `sparky:8081` slot and is reproducible with the commands
> quoted here.

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

## Design (proposed — not yet agreed)

1. **Widen the allowlist.** Add the three counters (and optionally the
   per-position family) to `@metric_names`. `put_metric/4` currently keys on
   `model_name`; the per-position series needs `position` retained, so either
   keep it as a map keyed by position or skip it in v1.

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
     cumulative_since: "engine start",   # NOT per-request
     scraped_at: <timestamp>
   }
   ```

   `enabled: false` when the engine reports no speculative family, so absence
   reads as "not speculating", never as zero acceptance.

3. **Surface in `/v1/serving`, and as gauges in `/metrics`.** Both are
   management-scoped, which is the right home for engine internals — and is
   exactly why the scope item below has to land with it or the whole thing is
   invisible to helm.

4. **Say "cumulative" in the field names or the docs.** The single largest
   footgun here is a consumer reading `acceptance_rate` as belonging to its own
   request. It does not. It is engine-wide since start. The harness must delta.

5. **Do not put it on the inference path.** `/v1/serving` scrapes on demand;
   do not add a per-request engine call to the gateway hot path.

## Deliverables

1. Speculative counters in `Airo.Adapters.VLLM`'s allowlist + parser, with the
   `position` label preserved.
2. A derived `speculative` block per deployment in `Airo.Serving.snapshot/1`,
   `enabled: false` when absent.
3. `airo_spec_decode_*` gauges in `AiroWeb.MetricsController`.
4. A management-scoped key for helm (or the scope added to `helm-prod` /
   `helm-dev`), **decided with jody** — it is a prod credential change.
5. Docs: a line in the README's build-details section, and a note in
   `DESIGN.md` that engine-internal metrics are management-scoped by design.

## Tests

- Parser: a fixture of real `/metrics` text (capture from sparky) yields the
  three counters and the per-position map; a fixture **without** the family
  yields `enabled: false`, not zeros.
- Derivation: acceptance rate, accepted-per-draft and tokens-per-step against
  the measured numbers above (37.75%, 2.63, 3.63) — these are the regression
  values.
- Division guard: zero drafts must not raise or produce `NaN`.
- `/v1/serving` includes the block for a speculating deployment and omits it
  for a non-speculating one; management scope still enforced (403 for an
  inference key).

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
  `/metrics` at the same moment, within rounding.
- A non-speculating slot (any Qwen slot, `pvegpu:8081`) reports
  `enabled: false`.
- helm can read it with its key, and its rows carry a real rate instead of
  `acceptance_reported: false` — or, if the scope decision goes the other way,
  helm deltas the engine directly and the sprint drops deliverable 4.

## Open questions for jody

1. **Scope.** Give helm a management key, or leave helm scraping engines
   directly and keep Airo's copy for the admin UI only? The second is less
   coupling; the first is the single-source-of-truth story.
2. **Per-position in v1?** It is the most useful tuning signal and the most
   awkward shape (a labelled array). Ship it, or defer it to a follow-up?

## Session note (2026-09-09)

MemPal was unreachable from that session (`ConnectionRefused` at session start;
the service itself was up and `claude mcp list` reported it connected — the
session's MCP client had bound to the failed state and does not rebind without
a restart). **Nothing from this investigation reached memory.** That is why
this file exists. Worth storing on restart:

- the two-`/metrics` correction, since the wrong version caused a real dead end
- the delta method as the way to measure acceptance per arm
- that per-request acceptance is absent from this build's wire format
