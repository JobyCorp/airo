# Sprint 22 — Engine parity & engine-aware capacity

> **Status: in progress (S22).**

Airo treats every agent-managed slot identically, but llama.cpp and vLLM are not
interchangeable behind that seam. Companion to
[DESIGN-vram-validation.md](../design/DESIGN-vram-validation.md) (S21, whose
model turns out to be llama.cpp-only) and
[DESIGN-slot-config.md](../design/DESIGN-slot-config.md) (S20, the config modal).

> **Goal (one sentence):** make Airo aware of which engine is behind a slot, so
> capacity validation, the launch modal, and local-model management stop
> applying llama.cpp's contract to vLLM — silently.

> **Why now.** `airo_agent` just closed its side of the gap (`fc3ad4f`:
> `honored_profile_keys/0`, `runtime_props/1`/`reap_orphans/0` as optional
> callbacks, `parallel` falling back to the resolved profile). That last change
> **arms a latent bug on this side**: `validate_config/1` computes
> `ctx_total_new = ctx × parallel`, which is llama.cpp's contract, and it was
> only ever correct for vLLM because the agent reported `parallel: nil`. That
> accident is now gone.

---

## The root cause

`grep -rn ':engine' lib/` returns nothing. `Airo.Config.Model` has no engine
field, and `Airo.Agents.Provenance.model_attrs/4` drops the `engine` the agent
sends in `/inventory`. Every agent-managed slot is `adapter_type: :openai` —
correct as a *wire* protocol, both speak OpenAI — so nothing downstream can tell
a GGUF slot from a vLLM slot. Items 1–4 below all follow from that.

`/inventory` already carries `"engine": "llama_cpp"` per model, so the config
modal can be engine-aware without touching the database; persistence is only
needed for consumers off that path.

---

## 1. `ctx_total_new` applies llama.cpp's contract to vLLM (armed)

`AiroWeb.Admin.AgentLive.validate_config/1`:

```elixir
ctx_total_new = ctx && ctx * (config.parallel || 1)
```

llama.cpp's `-c` **is** `ctx × parallel`. vLLM's `--max-model-len` is the
per-request window and `parallel → --max-num-seqs`; its KV pool is sized by
`gpu_memory_utilization`, not by `ctx × seqs`. Measured on sparky's DeepSeek
(`--max-model-len 1048576`, `--max-num-seqs 6`):

```
ctx_total_current: nil (today) → :cold, 60,000 MB      — identical either way
ctx_total_current: ctx         → before: 118,415 MB
                                 after:  410,490 MB    ← ×6, budget 118,318
```

Dormant only because vLLM reports `ctx_total: nil` so `Capacity.validate/1` takes
the cold branch and never reads `ctx_total_new`. The moment vLLM becomes
calibratable, Airo projects 3.5× the real footprint and **hard-blocks a load that
is currently running** — the guard refuses server-side, not just in the UI.

**Do:** derive `ctx_total_new` from the engine's contract, not unconditionally.

## 2. VRAM validation is llama.cpp-only, and says the wrong thing

```
vLLM resident slot   → fits?: :cold     (weights floor only)
llama.cpp resident   → fits?: false     (real calibrated projection)
```

`Capacity.per_ctx_mb/3` calibrates from `ctx_total_current`, which vLLM has no
runtime analogue for. So S21's whole calibrated model degrades to the weights
floor for vLLM — including the 685B DSpark cluster, the most VRAM-critical thing
in the fleet.

Worse, the UI explains it as *"Cold model: weights fit, but the context's KV cost
can't be validated until it's loaded."* On a resident vLLM slot the model **is**
loaded; an operator reads that as "not yet" rather than "not possible here".

**Do:** distinguish *"not calibrated yet"* from *"this engine can't be calibrated
this way"* and say so honestly. Not inventing a projection vLLM's architecture
doesn't support is the point — S21's `:cold` was already the right *value*, only
the explanation was wrong.

## 3. The launch modal offers knobs the engine drops

`@form_profile_keys` mixes both engines with no gating:

- `temperature`/`top_p`/`repeat_penalty`/`presence_penalty`/`frequency_penalty` —
  llama.cpp maps all five to launch flags; **vLLM maps none**, deliberately.
- `nnodes`/`tensor_parallel_size` — vLLM-only, meaningless on llama.cpp.

The agent now declares `honored_profile_keys/0`, but it is an Elixir callback,
**not on the HTTP API**, so Airo cannot consult it remotely. Mirroring the full
key list here would recreate exactly the drift that left `mmproj` unreachable.

**Do:** gate by *knob group* (sampling vs cluster) on the engine — coarse enough
not to duplicate the contract. Exposing `honored_profile_keys` over the agent's
API is a follow-up, tracked below.

## 4. Agent-managed vLLM loses the vLLM adapter's local management

```
adapter_type :openai (every agent slot) → LocalProvider capabilities: []
adapter_type :vllm   (external)         → [:catalog, :inspect_model, :runtime_info]
```

`Airo.Adapters.VLLM` scrapes `/metrics` (KV-cache usage, requests running/waiting,
preemptions, token totals) and `max_model_len`; `OpenAICompatible` implements no
`LocalProvider` at all. In prod `qwen-tts`/`vllm`/`vllm-spark` get all of it while
`sparky:8081` and the rest of the managed fleet get none — same engine, opposite
treatment, decided only by who manages it.

**Do:** resolve the local-management module by the slot's engine when the
provider is agent-managed.

## 5. Stale `Airo.Registry` doctests

```elixir
iex> Airo.Registry.fetch(:vllm)       #=> documented OpenAICompatible, actual VLLM
iex> Airo.Registry.fetch(:anthropic)  #=> documented :no_adapter, actual {:ok, Anthropic}
```

No `doctest Airo.Registry` anywhere, so nothing catches it. It is the first
module a reader consults to answer "what handles vLLM?".

**Do:** fix both and add the doctest so they can't rot again.

---

---

## What shipped

`Airo.Engines` is the one place the differences are written down, so `case
engine` doesn't get copied into every caller. An unknown engine always takes
llama.cpp's path — what Airo assumed before the module existed, so an
unrecognised backend can't silently change how a slot is validated.

| # | Change |
| --- | --- |
| enabler | `models.engine` (string, not an enum — the agent owns the vocabulary); `Provenance` stops dropping the engine `/inventory` sends |
| 1 | `Engines.ctx_total/3` per contract; `validate_config/1` no longer multiplies by `parallel` unconditionally |
| 2 | `Capacity.validate/1` gains `:uncalibratable`, distinct from `:cold`; the modal explains vLLM sizes its KV pool from `gpu-memory-utilization` instead of claiming the model isn't loaded |
| 3 | Sampling knobs hidden on vLLM (with a pointer to request defaults); cluster knobs hidden on llama.cpp. The advanced JSON stays on every engine |
| 4 | `LocalModels` resolves the management module by engine for agent-managed slots; external providers still resolve on `adapter_type` |
| 5 | Registry docs corrected + `doctest Airo.Registry` so they can't rot again |

**Verification gap, stated plainly.** The knob gating in #3 is covered at the
predicate level (`Engines.honors_sampling?/1`, `clusterable?/1`) but **not at the
render level**. `AgentLive` loads its inventory through `Control.inventory/2`,
which takes no injectable stub, and the dev host reports `offline` because the
fleet's agents point at prod — so neither a LiveView test nor a browser check can
open the modal with a vLLM model present. Adding a seam to `Control` for one test
was out of proportion; the honest state is that the predicates are proven and the
two `:if=` bindings are not.

## Out of scope / follow-ups

- **Expose `honored_profile_keys` on the agent's HTTP API** so Airo can gate the
  modal per-key instead of per-group. Agent-side; needed for #3 to be exact.
- `effective_parallel/1` tidy in `airo_agent` — `slot_info/1` open-codes what
  `emit/3` calls the helper for. Equivalent today; drift risk.
- Per-model KV learning, automatic placement (still out of scope from S18/S21).
