# S15 — Local ONNX classifier (Ortex, on-CPU validation slice)

**Status:** [x] done  
**Branch:** `sprint/15-local-onnx-classifier-ortex-on-cpu-validation-slice`  
**Design:** [DESIGN-local-classifier.md](../design/DESIGN-local-classifier.md)

## Scope

Depends on S13 (classifier seam, `router`/`router_config`, `Classifier.score/2`).
Prove the routing classifier can run **natively on the BEAM, on CPU, end-to-end**
via Ortex with an **off-the-shelf** ONNX model — before any fine-tune or enforce
cutover. Goal: a `:classify` alias can compute `route.class` with **zero GPU /
Infinity call**, inside the existing latency budget. v1 swaps the **axis**, not
just the engine: route on a **graded 0–1 complexity score** (NVIDIA
`prompt-task-and-complexity-classifier`, DeBERTa-v3-base, single pass) thresholded
into a tier ladder — fixing the S13 topic-entailment path that treats code as a
binary signal. Stock model only; the fine-tuned router and switching the default
backend are a later sprint.
- **Dep chain (build host):** add `{:ortex, …}` + `{:tokenizers, …}` to `mix.exs`;
  install Rust + sort the native build (ORT binary fetch) **on the build host**
  (we build locally and ship a precompiled release tarball — the VM never runs
  `mix compile`); `mix deps.get` + `compile --warnings-as-errors` clean; `mix
  precommit` green; the NIF `.so` + ORT lib ride inside the tarball, VM needs no Rust
- **Model artifact + export gate:** NVIDIA complexity classifier — a **custom
  multi-head** model, *not* `optimum-cli`-exportable, and DeBERTa-v3 export is a
  documented silent-wrong hazard. Hand-export on the fleet, **gate on numerical
  equivalence (torch vs ONNX logits)**; fall back to `deberta-v3-base-zeroshot`
  (clean export, Infinity parity ref) if it fails. `mix airo.fetch_model` →
  `priv/models/<name>/` (**gitignored**, fetched **before `mix release`** so it
  ships), checksum + recorded graph-input/head-order contract
- **`Airo.Routing.LocalClassifier`:** load ORT session + tokenizer **once** at boot
  (`:persistent_term` / named process, low intra-op threads, warmup); single-text
  encode (no pair) → run → **`process_logits` ported to Nx** (softmax + weighted
  complexity scalar) → return `%{class => c}` per tier label (+ diagnostic dims /
  task_type for the shadow log) in the exact shape `Classifier.decide/2` consumes
- **Seam, non-breaking:** `router_config["backend"]` (`:infinity | :ortex`,
  default `:infinity`) dispatched inside `Classifier.score/2`; Infinity path
  untouched. `labels` become a **threshold ladder** (`class` + `min`, highest tier
  first); `parse_config` branches requirements by backend (ortex needs `model`, not
  `classifier`). Backend selectable via seed/config — admin UI toggle deferred to
  the cutover sprint (no UI work, so no `joby_kit.lint` gate)
- **Validation harness:** a mix task / test that runs a fixed prompt set on CPU
  through the `:ortex` backend, asserts **decision parity** on the §10 set **and the
  code-nuance cases** (string-reverse → edge, multi-file refactor → deep — the
  regression topic-entailment failed), and **logs p50/p95 latency** (single pass;
  target ≤ the ~45ms Infinity LAN hop)
- **DoD extra:** dep chain compiles clean **on the build host** (not the VM); export
  passed the equivalence gate (or fell back, recorded); a real chat request through a
  `:classify` alias with `backend: :ortex` produces a `route.class` with **no
  Infinity/GPU call** (verified — no outbound classify); `LocalClassifier`
  unit-tested against the bundled real ONNX (deterministic scores + code-nuance
  cases); latency logged under budget; the `:infinity` path is byte-for-byte
  unchanged (non-regression test)
