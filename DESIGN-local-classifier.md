# Airo — Local ONNX routing classifier (S15)

Spec for **S15 — Local ONNX classifier (Ortex, on-CPU validation slice)**.
Companion to [DESIGN-chat-routing.md](./DESIGN-chat-routing.md) (the S13 classifier
this extends) and [DESIGN.md](./DESIGN.md) §9 (Routing). This is the implementation
hand-off: self-contained, names exact files/functions, and fixes the decisions so
the build doesn't re-derive them.

> **Goal (one sentence):** prove the routing classifier can run **natively on the
> BEAM, on CPU, end-to-end** via **Ortex** with an **off-the-shelf** ONNX model —
> a `:classify` alias computes `route.class` with **zero GPU / Infinity call** and
> inside the existing latency budget — *before* any fine-tune, INT8 quantization,
> or enforce cutover.

> **Model pivot (this revision).** v1 swaps the *axis*, not just the engine. The
> S13 path scores **topic entailment** ("does this prompt entail *requires code*"),
> which treats code as a binary signal — string-reversal and a multi-file refactor
> both light up the one `:deep` label. DESIGN-chat-routing §10 already records this
> wall (appending "coding" to the label dragged trivial code to 0.529 — *"rejected,
> no gain"*). S15 instead runs **NVIDIA's `prompt-task-and-complexity-classifier`**
> (DeBERTa-v3-base, multi-head) to produce a **graded 0–1 complexity score** that is
> *decoupled from topic*, then thresholds it. Trivial code scores low → edge;
> high-reasoning / multi-constraint work scores high → deep (→ cloud later). This is
> the answer to "how much can the local 35b do before I pay for the slow/expensive
> model." The S13 zero-shot NLI deberta remains the **clean-export fallback** and the
> **Infinity parity reference** (§6) if the complexity model's export proves unviable.

> **Build environment.** This sprint is built in the **Tidewave browser editor**
> against a running Airo server. Tidewave's live runtime is an asset — use it to
> smoke `Ortex.run/2` in `iex`, to hit the real Infinity endpoint for the §6 parity
> baseline, and to measure CPU latency in-process. **Native-dep caveat (§11):** the
> Rust/ORT toolchain must exist **where `mix compile` runs**, and the server needs a
> **restart** after the NIFs build — a hot reload won't pick up new native code.

> **Deploy model (confirmed).** Airo is **built locally and shipped as a precompiled
> release tarball** (`bin/deploy.sh`: `mix release` on a Linux x86_64 build host →
> `scp` → the VM extracts and runs `bin/server`; the **VM never runs `mix compile`**).
> Consequences that shape T0/T1 (§5): the **Rust toolchain lives on the build host**
> (not the VM — the VM only needs the ORT shared lib loadable at runtime); the
> precompiled NIF `.so`, the ORT lib, and the **model artifact** all travel **inside
> the tarball**; and because `priv/models/` is gitignored, the model must be fetched
> **before `mix release`** or it won't ship. The build host currently has **no
> `cargo`/`rustc`** — installing it is the real T0 gate.

---

## 1. Why this is still small

The S13 classifier was built with exactly this swap in mind. Four facts keep S15
contained even with the model/axis change:

1. **The seam is one private function.** `Airo.Routing.Classifier.score/2`
   (`lib/airo/routing/classifier.ex:141–160`) is the *only* place that talks to an
   inference engine. It returns `{:ok, scores}` where `scores = %{class => float}`.
   `decide/2` (`:205–209`) walks `config.labels` highest-tier-first and returns the
   first `class` whose `scores[class] >= min`, else `default_class`. The
   `Gateway.maybe_classify/4` hook (`gateway.ex:284–323`), shadow/enforce, and the
   `gateway.route.classified` log all consume that map. **Swap the engine inside
   `score/2`, return the same-shaped map, done.**

2. **A graded score maps onto `decide/2` with zero decision-logic change.** The
   complexity model emits one scalar `c ∈ [0,1]`. `LocalClassifier.score/2` returns
   that scalar under **every tier label's `class` key** — `%{"deep" => c}` for v1,
   `%{"cloud" => c, "deep" => c}` once a cloud tier exists. `decide/2`'s
   highest-first walk then yields the escalation for free (`c=0.2` → edge, `c=0.6` →
   deep, `c=0.8` → cloud). **No `decide/2` edit.** The labels list becomes a
   *threshold ladder*, not a set of NLI hypotheses — fixing the code-as-binary
   problem without re-litigating label wording.

3. **Single pass, bare prompt.** Unlike the NLI path (one `(premise, hypothesis)`
   pair *per label*, N forward passes), the complexity model takes the **prompt
   alone** and scores **all dimensions in one forward pass**. So it's *simpler and
   faster* on CPU than what it replaces, and gets cheaper-relative as tiers grow.

4. **Fail-open already wraps everything.** `class_for/2` is total by contract
   (function-level `rescue`/`catch`, `classifier.ex:52–58`); the gateway treats
   `:skip`/`{:error, _}` as "leave routing untouched" (`gateway.ex:322–323`). A model
   that fails to load, or an Ortex/Tokenizers explosion, collapses to `{:error, _}`
   and the request behaves as an ordinary unrouted alias — **no new failure mode**.

So the job is: get the dep chain to compile **on the build host**, export + verify
the model to ONNX, load it once on CPU, and make a second `score/2` backend return
the same map shape carrying a graded complexity score. Validation-only.

## 2. Engine choice (fixed — do not re-litigate)

**Ortex + Tokenizers.** Decided in conversation and recorded in memory
(`project-airo-routing-ortex`). Rationale, condensed:

- The CPU win is **not "Rust"** — EXLA is also native C++. It's INT8 quantization +
  ONNX Runtime's MLAS/VNNI transformer kernels, which Bumblebee/EXLA does not give
  turnkey. (INT8 is deferred to the fine-tune sprint; see §9.)
- ONNX is the universal boundary that keeps Airo **architecture-agnostic** — swap the
  `.onnx`, reload, never re-check "can Bumblebee load this?". This matters *now*: the
  NVIDIA model is a **custom multi-head class** Bumblebee can't load, and a future
  SetFit/fine-tune can't either. Ortex consumes any exported graph.
- Training/export is **not** on the Elixir box — it's on the user's fleet (5090 /
  Spark). Airo only ever *consumes* ONNX. Ortex is inference-only — exactly right.

`{:tokenizers, …}` (HF tokenizers NIF) handles encoding. DeBERTa-v3 uses a
**SentencePiece** tokenizer (`DebertaV2TokenizerFast`); export it as `tokenizer.json`
(via `save_pretrained`) so the Rust lib can load it. Single-text encoding here (no
pair) → `input_ids` / `attention_mask` (+ `token_type_ids` if the traced graph keeps
them — T1 records this).

> **Superseded (S16).** The `router_config` keys below (`backend`, `model`, `score`,
> `labels`, …) now live in the system-level `RoutingSetting` singleton
> (`/admin/routing`), not per alias. The backend dispatch, `LocalClassifier`, and the
> graded-score contract are unchanged. See [DESIGN-routing-settings.md](./DESIGN-routing-settings.md).

## 3. Data-model / config change

**No migration.** Reuse `aliases.router_config` (the free `:map` from S13). Add
optional keys, all backward-compatible:

```jsonc
{
  // ... existing S13 keys (input, default_class, timeout_ms) unchanged ...
  "backend": "ortex",                  // "infinity" (default, absent ⇒ infinity) | "ortex"
  "model":   "nvidia-prompt-task-complexity",  // dir under priv/models/, ortex only
  "score":   "overall",                // ortex/complexity only: which scalar to threshold
                                       //   "overall" (NVIDIA's weighted formula, default)
                                       //   | a custom weight map over dims (see §5 T2)
  "labels": [                          // now a THRESHOLD LADDER (highest tier first)
    { "class": "deep", "min": 0.45 }   // v1 edge-vs-deep: one threshold. cloud later = add
                                       //   { "class": "cloud", "min": 0.75 } above this row.
  ],
  "default_class": "edge"              // below the lowest threshold ⇒ the fast default
}
```

`parse_config/1` (`classifier.ex:63–82`) changes:
- `backend: as_atom(rc["backend"], :infinity)`, constrained to `[:infinity, :ortex]`
  (anything else ⇒ `:infinity`, never a hard error).
- **Branch the requirements by backend.** Today it requires a binary `classifier`.
  Keep that for `:infinity`. For `:ortex`, **`classifier` is ignored**; instead require
  `model: as_string(rc["model"], nil)` non-nil — nil/unknown ⇒ `{:error, :bad_config}`
  (fail-open at the hook). `labels` non-empty is required for **both**.
- For `:ortex`, the label `"label"` string and `hypothesis_template` are **ignored**
  (there is no per-label NLI hypothesis — the score is topic-free). Only `class` +
  `min` are read from each label.

`input`, `default_class`, `timeout_ms`, and the whole decision step are **shared by
both backends** — that's the point.

## 4. Fixed decisions (do not re-litigate)

- **Backend swap lives entirely inside `score/2`.** `class_for/2`, `decide/2`,
  `extract_input/2`, the gateway hook, and the return contract are untouched.
  `score/2` dispatches on `config.backend`:
  ```elixir
  defp score(%{backend: :ortex} = config, premise),
    do: Airo.Routing.LocalClassifier.score(config, premise)
  defp score(config, premise), do: score_infinity(config, premise)  # today's body, verbatim
  ```
- **Same map shape, graded score.** `LocalClassifier.score/2` returns
  `{:ok, %{class => c}}` — the same shape `decide/2` consumes — with `c` the chosen
  complexity scalar under **each** tier label's class key. It **also** folds in
  diagnostic keys (`"_dims" => %{...}`, `"_task" => "Code Generation"`) for the
  shadow log; `decide/2` only reads the tier classes, so the extra keys are inert.
- **Graded difficulty, not topic.** The score is computed from the model's
  reasoning / domain-knowledge / constraints / creativity / context / few-shot heads
  — **never** from "is this code." This is the whole reason for the model swap (§1,
  intro). Code routes by *how hard the code task is*, the §10 separation we want.
- **The score weighting is a knob.** `score: "overall"` uses NVIDIA's published
  formula (`0.35·creativity + 0.25·reasoning + 0.15·constraints + 0.15·domain +
  0.05·context + 0.05·few_shots`). That weighting was tuned for data curation, not
  code routing; the per-dimension scores are all returned, so a **routing-specific
  reweighting** (e.g. emphasize reasoning + domain_knowledge + constraints for code)
  is a `router_config` edit calibrated on shadow logs — *not* a code change. v1 ships
  `"overall"`; better weights are a calibration follow-up.
- **Load once, never per request.** The ORT session + tokenizer load at boot into a
  supervised holder (`:persistent_term` written by a small GenServer in the app tree),
  with a warmup inference. Per-request `score/2` only encodes + runs + post-processes.
- **Threads pinned low.** ONNX Runtime defaults to a large intra-op pool that fights
  the BEAM schedulers on a busy Phoenix box — set intra-op (and inter-op) threads to
  1–2 at `Ortex.load`.
- **Fail-open is preserved.** Model/tokenizer load failure at boot ⇒ the holder
  records `:unavailable`; `LocalClassifier.score/2` returns `{:error,
  :model_unavailable}` ⇒ gateway leaves routing untouched. A routed alias on a box
  where the model didn't load behaves as an ordinary priority alias.
- **No binaries in git.** ONNX + `tokenizer.json` live under `priv/models/<name>/`,
  **gitignored**, fetched by `mix airo.fetch_model` with a recorded checksum, and
  bundled into the release tarball at build time (§5 T1, deploy model above).
- **Validation-only scope.** No enforce flip, no default-backend change, no admin UI
  toggle, no fine-tune, no INT8. All deferred (§9). `:infinity` stays the default
  backend; `:ortex` is opt-in per alias via `router_config` (seed/config).

---

## 5. Tasks

Order matters; T0 and T1's export-verification gate the rest.

### T0 — Spike: dep chain on the **build host** + one real `Ortex.run` on CPU
- **Install the Rust toolchain on the build host** (the machine that runs
  `bin/deploy.sh` / `mix release`; currently no `cargo`/`rustc`). The VM needs **no**
  Rust — only the ORT shared lib at runtime, which ships in the tarball.
- Add `{:ortex, "~> 0.1"}` and `{:tokenizers, "~> 0.5"}` to `mix.exs`; `mix deps.get`;
  confirm the native build resolves (Rust present; ORT binary downloads). Compile
  `--warnings-as-errors` clean; `mix precommit` still green.
- In the **Tidewave runtime** (`iex`): hand-load *any* small ONNX classifier +
  tokenizer, encode one input, `Ortex.run/2`, softmax — prove the end-to-end native
  call works **in-process on CPU** before writing any module. **Restart** the server
  first (§11: NIFs don't hot-reload).
- **Verify the DeBERTa-v3 backbone specifically loads + runs in the bundled ORT on
  CPU** (its disentangled-attention `gather`/`einsum` ops are the known-fragile part —
  see T1). Record any ORT op/opset gap here — this is a gate.

### T1 — `mix airo.fetch_model` + the NVIDIA model artifact (with an **export-correctness gate**)
The NVIDIA model is **not** a standard `AutoModel` and **not** `optimum-cli`-exportable
as-is: it's a custom `CustomModel` (DeBERTa-v3-base backbone → mean-pool → 8 linear
heads). And DeBERTa-v3 ONNX export is a **documented silent-wrong hazard** (optimum
issues #2075/#968: export "succeeds" but produces incorrect logits). So:

- **Export on the fleet** with a hand-written script (torch + NVIDIA's custom code):
  `torch.onnx.export` of `(input_ids, attention_mask[, token_type_ids])` → the head
  **logits** as named outputs (the 6 complexity heads + `task_type`; `no_label_reason`
  optional). Use **opset 17+**, dynamic axes for batch + sequence. Export `f32`
  (INT8 is the next sprint). Save the fast tokenizer as `tokenizer.json`.
- **GATE — numerical equivalence.** Run the torch model and the ONNX model on a fixed
  prompt set; assert max-abs logit delta `< 1e-3` per head. If it fails (the
  disentangled-attention export is wrong), **fall back to
  `MoritzLaurer/deberta-v3-base-zeroshot-v2.0`** (clean export, the §6 parity
  reference) for v1 and file the complexity model as a fast-follow. Record the verdict
  in §10. *Do not ship an unverified DeBERTa-v3 export.*
- `mix airo.fetch_model <name>`: fetch `model.onnx` + `tokenizer.json` into
  `priv/models/<name>/`, verify a checksum, and **record the contract**: the exact
  graph **input names + order** (does it keep `token_type_ids`?), the **output head
  order**, each complexity head's **bucket count + the value scale** used by
  `process_logits`, and the `id2label`/argmax mapping for `task_type`. Add
  `priv/models/` to `.gitignore`.
- **Deploy wiring:** ensure `bin/deploy.sh` fetches the model **before** `mix release`
  (or the gitignored artifact won't be in the tarball). Note it in the script /
  `DEPLOY.md`.

### T2 — `Airo.Routing.LocalClassifier`
New module `lib/airo/routing/local_classifier.ex`.
- **Holder:** a tiny GenServer (added to `Airo.Application` children, before
  `AiroWeb.Endpoint`) that on `init` loads the ORT session (low threads) + tokenizer
  for the configured model, runs a warmup inference, and writes the handle to
  `:persistent_term`. Load failure ⇒ store `:unavailable` (do **not** crash the app).
- **`score(config, premise)`:**
  1. Tokenize the **bare premise** (single text, no pair) via `Tokenizers` →
     `input_ids` / `attention_mask` (+ `token_type_ids` iff the graph kept it) → `Nx`
     tensors in the **names/order the graph declares**.
  2. `Ortex.run` → the head logit tensors.
  3. **Post-process in `Nx`, porting NVIDIA's `process_logits` exactly** (verified by
     T1's numerical gate): per complexity head `softmax` over its buckets → weighted
     scalar in `[0,1]`; combine into the routing score per `config.score`
     (`"overall"` ⇒ the published weights; a custom weight map ⇒ that linear combo).
     `argmax` `task_type` for the diagnostic.
  4. Return `{:ok, scores}` where `scores = Map.new(config.labels, &{&1.class, c})`
     merged with `%{"_dims" => dim_scalars, "_task" => task_label}`. Bound the work by
     `config.timeout_ms` (reuse `run_bounded/2`, `classifier.ex:213–230`). Holder
     `:unavailable` ⇒ `{:error, :model_unavailable}`.

> **Dirty-NIF note (§11):** `Ortex.run` is a dirty NIF, so `run_bounded`'s
> `brutal_kill` on timeout returns `{:error, :timeout}` to the caller correctly but
> won't actually interrupt the in-flight NIF (it abandons the result). Fine for
> fail-open; just don't expect the budget to *cancel* CPU work.

### T3 — Wire the backend dispatch
- Extend `parse_config/1` with the backend-branched requirements + `model` + `score`
  (§3); add the `as_atom/2` guard; relax the `classifier`-required rule for `:ortex`.
- Split `score/2` into the two-clause dispatch (§4); move today's body into
  `score_infinity/2` **verbatim** (no behavior change for `:infinity`).
- That's the whole gateway-side change — `class_for/2` and the hook are untouched.

### T4 — Validation harness (the on-CPU end-to-end proof)
A `mix airo.validate_classifier` task (or tagged test) against the `:ortex` backend on
CPU:
- **Decision parity on the §10 set** (the 7 calibrated edge/deep prompts): the local
  model need not match Infinity's floats, but the **routing decision must match** for
  all 7.
- **The nuance cases this sprint exists for** (assert explicitly): "Write a Python
  function that reverses a string" → **edge**; "Refactor the auth module across three
  files" → **deep**. i.e. *code is graded by difficulty, not flagged as a class.*
  This is the regression the topic-entailment path could not pass (§10 of
  DESIGN-chat-routing).
- Optionally, when a live Infinity classifier is reachable (Tidewave runtime), print a
  side-by-side per-prompt delta for calibration.
- **Log p50/p95 single-inference latency on CPU** (single pass; target ≤ the ~45 ms
  Infinity LAN hop from §10 — record the real f32 number).

### T5 — Tests
- `LocalClassifier` unit test against the **bundled real ONNX** (deterministic scores
  for fixed inputs, incl. the two nuance cases) — not a stub; this is the point.
- `score/2` dispatch: `backend: :ortex` routes to `LocalClassifier`, makes **no**
  Infinity HTTP call (assert no outbound classify request); `backend: :infinity` (and
  absent backend) is **byte-for-byte unchanged** (non-regression).
- `parse_config`: ortex parses `model`/`score`/threshold-labels; `:ortex` + missing
  `model` ⇒ `:bad_config`; `:infinity` still requires `classifier`.
- Boot/load failure ⇒ `score/2` returns `{:error, :model_unavailable}` and the gateway
  leaves routing untouched (fail-open regression).

### T6 — Docs
- Update §10 with the **measured CPU latency** + the export verdict + the chosen model
  + the decision-parity result.
- `DESIGN.md` §9: note `router_config.backend` (`infinity | ortex`) as a classifier
  **engine** dimension *and* that ortex routes on a **graded complexity score**
  (threshold ladder) rather than topic entailment.
- `SPRINTS.md`: tick S15 + append the status-log line on merge.

---

## 6. Rollout

1. **Validate (this sprint):** NVIDIA complexity model (f32), `:ortex` backend opt-in
   on a test alias; prove decision-parity on the §10 set **plus the code-nuance
   cases**, and record CPU latency. `:infinity` stays the default; production routing
   unchanged. The deberta-v3 zero-shot NLI is the fallback/parity reference.
2. **Calibrate (separate):** read `gateway.route.classified` shadow logs (now carrying
   the per-dimension breakdown + task type) → tune the threshold ladder and, if
   needed, a routing-specific dimension weighting (`router_config.score`). Add
   **outcome logging** (did the served tier suffice?) as the dataset a future
   fine-tune would need.
3. **Next sprint (separate):** fine-tune *only if* calibrated graded-difficulty still
   misroutes at the 35b's specific frontier → export ONNX → **INT8 quantize** → swap
   the artifact, flip the default backend, add the `/admin/aliases` backend toggle,
   then enforce.

## 7. Definition of Done (this sprint)

Global DoD from `SPRINTS.md` (`mix precommit` green; new behavior tested against a real
artifact, not live; `SPRINTS.md` ticked; branch merged) **plus**:
- Dep chain compiles clean **on the build host** (Rust/ORT present); the release
  tarball carries the NIF `.so` + ORT lib + the model artifact, and the model loads on
  the VM at boot. *(Not "compiles on the VM" — the VM never runs `mix compile`.)*
- The ONNX export passed the **numerical-equivalence gate** (or v1 fell back to the
  deberta-v3 zero-shot NLI, recorded in §10).
- A real chat request through a `:classify` alias with `backend: :ortex` computes a
  `route.class` with **no Infinity/GPU call** (verified — no outbound classify).
- `LocalClassifier` unit-tested against the bundled real ONNX; **decision-parity on
  the §10 set + the two code-nuance cases**; CPU p50/p95 latency recorded in §10.
- `:infinity` backend path is byte-for-byte unchanged (non-regression test);
  model-load failure fails open.

## 8. Test plan summary
`LocalClassifier` unit (real ONNX, deterministic scores, code-nuance cases, fail-open
on unavailable) · `score/2` dispatch (ortex makes no HTTP call; infinity unchanged) ·
validation harness (§10 decision-parity + code nuance + latency) · `parse_config`
(backend/model/score parse, threshold-labels, bad-config when ortex + missing model;
infinity still needs classifier).

## 9. Non-goals / deferred (next sprint)
- **Fine-tuned classifier** (distilled from shadow + outcome logs to the 35b's actual
  frontier) — S15 is off-the-shelf only; justified *only if* calibration proves the
  generic complexity score insufficient.
- **INT8 quantization** — the real CPU perf lever, but validation runs f32 first so the
  dep-chain + export-correctness are isolated from the quant step.
- **Cloud tier** — the graded score supports it natively (add a `{"class":"cloud"}`
  threshold row); deferred until a `:cloud` deployment exists.
- **Cascade / generate-then-verify routing** (run edge, verify, escalate) — a stronger
  answer to "max out the local model" for the code path, but it acts on model *output*,
  not the pre-dispatch hook; a sibling design, not this sprint.
- **Default-backend flip + enforce + admin UI toggle** — operational, after parity is
  proven.
- **Routing-specific dimension reweighting + outcome logging** — calibration follow-up
  (§6.2); v1 ships NVIDIA's `"overall"` weights and the diagnostic breakdown.

## 10. Results (measured 2026-06-18)
- **Chosen model:** NVIDIA `prompt-task-and-complexity-classifier` (DeBERTa-v3-base,
  ~0.2B, f32), HF revision `fea1121511eafabaf7dd6fc66863dcb04f74defb`.
  `model.onnx` 703 MB (`sha256 1e77d482…b208e5`), `tokenizer.json` 8.3 MB
  (Unigram, 128k vocab, `sha256 4b4f6023…27b929`). No fallback needed.
- **ONNX export numerical-equivalence gate: ✅ PASS** — torch vs onnxruntime (CPU,
  7 prompts): `max|Δ| complexity_dims = 7.75e-7`, `overall = 2.24e-7`, task_type
  argmax 0/7 mismatch. In-graph `process_logits` cross-checked vs NVIDIA's native
  impl (overall ~1e-5, pure rounding).
- **Graph inputs:** `input_ids` + `attention_mask` (Int64, dynamic) — **no
  `token_type_ids`** (dropped on export). **Outputs:** `complexity_dims [B,6]`
  (order `creativity, reasoning, constraint, domain_knowledge,
  contextual_knowledge, num_few_shots`), `overall_complexity [B,1]`,
  `task_type_probs [B,11]` (idx→label = `config.task_type_map`, idx 11 "Unknown"
  dropped by the `[:11]` slice). Contract recorded in `mix airo.fetch_model`.
- **Routing weighting (the §4 knob):** `constraint 0.55 · reasoning 0.35 ·
  creativity 0.05 · contextual_knowledge 0.05` (domain excluded — it's the
  topic-trap), **deep threshold 0.20**. Default `overall` separates 7/7 too but
  with a thin ~0.03 margin; this weighting gives **~0.11** (edge max 0.141 vs deep
  min 0.255). Starting point — widen the sample via shadow logs before locking.
- **§10-set decision parity: 7/7** (`mix airo.validate_classifier`).
- **Code-nuance cases:** "reverse a string" → **edge** (0.103) · "refactor across
  three files" → **deep** (0.383). Code graded by difficulty, not flagged binary.
- **CPU latency** (`score/2`, f32, single pass, n=210): **p50 44.0 ms · p95
  80.5 ms** (min 17.3 / max 110) — at parity with the Infinity ~45 ms LAN hop,
  **zero GPU**, well under the 200 ms budget. (INT8 next sprint should beat it.)
- **ORT thread settings:** defaults — Ortex 0.1.10 doesn't expose intra/inter-op
  thread counts. Mitigated by `Ortex.run` being a dirty NIF; pin (OMP env / Ortex
  PR) before any production/enforce cutover.

## 11. Appendix — BEAM / Ortex / export ops notes
- **Build locally, ship the tarball.** `mix compile`/`mix release` run on the build
  host; the VM extracts a precompiled release and runs `bin/server`. So: Rust/ORT
  toolchain on the **build host**; the NIF `.so` + ORT shared lib + `priv/models/*`
  ride **inside** the tarball; the VM needs the ORT lib loadable but **no Rust**.
  Build-host arch must match the VM (`deploy.sh` already enforces Linux x86_64).
- **Fetch the model before `mix release`.** `priv/models/` is gitignored; `mix release`
  bundles `priv/`, so an un-fetched model silently ships nothing and the holder boots
  `:unavailable`. Wire the fetch into `bin/deploy.sh` ahead of the release step.
- **DeBERTa-v3 export is a silent-wrong hazard.** Disentangled attention trips
  `optimum-cli`/tracers (issues #2075/#968) — export can "succeed" yet be numerically
  wrong. The T1 equivalence gate (torch vs ORT logits) is mandatory; opset 17+.
- **Custom multi-head model.** NVIDIA's classifier is a `CustomModel` (mean-pool + 8
  linear heads), not an `AutoModel` — export via a hand-written `torch.onnx.export`
  exposing the head logits; do `process_logits` (softmax + weighted scalar) in `Nx`.
- **Dirty NIF:** `Ortex.run` runs on a dirty scheduler (won't block normal
  schedulers), but pin ORT's intra/inter-op threads low (1–2) so it doesn't
  oversubscribe cores under chat load. Timeout abandons, doesn't cancel, the NIF.
- **Load once:** never `Ortex.load` per request — hold the session in
  `:persistent_term` via the boot GenServer; warm it with one inference at startup.
- **Tokenizer:** DeBERTa-v3 = SentencePiece (`DebertaV2TokenizerFast`); ship the fast
  tokenizer as `tokenizer.json`. Single-text encode (no pair) here.
- **Footprint:** f32 deberta-base ≈ 700 MB on disk / in memory; INT8 (next sprint)
  roughly quarters it. Size the VM accordingly.
- **License:** NVIDIA Open Model License (permits commercial use + derivatives — read
  before shipping). The zero-shot fallback (MIT/Apache) is clean.
- **Tidewave build caveat:** new native deps (Ortex/Tokenizers) take effect only after
  `mix deps.get` + compile-with-toolchain-present + **server restart** — a live reload
  won't load freshly built NIFs. Do the T0 dep-chain step as a restart.
