defmodule Airo.Engines do
  @moduledoc """
  What differs between the inference engines behind an agent-managed slot (S22).

  Every managed slot is `adapter_type: :openai` — that names the *wire protocol*,
  and llama-server and vLLM are both OpenAI-compatible there. Behind it they are
  not interchangeable, and Airo used to apply llama.cpp's assumptions to both.
  This module is the one place those differences are written down, so a `case
  engine` doesn't get copied into every caller and drift.

  The engine of a managed slot comes from `Airo.Config.Model.engine`, populated
  from the agent's `/inventory`. `nil` (unknown, or an external provider) is
  always treated as llama.cpp's behaviour, which is what Airo assumed before this
  module existed — an unknown engine must not silently change how a slot is
  validated.

  > **Source of truth is `airo_agent`.** Each fact below mirrors an adapter in
  > `airo_agent/lib/airo_agent/engine/`. Deliberately kept coarse: mirroring the
  > adapters' full profile-key lists is what left llama.cpp's `mmproj`
  > unreachable for a release, so `honors_sampling?/1` gates a *group* of knobs
  > rather than enumerating keys.
  """

  @llama_cpp "llama_cpp"
  @vllm "vllm"

  @type engine :: String.t() | nil

  @doc """
  Total KV budget a context setting implies, in tokens — the number VRAM scales
  with.

  The engines' context flags mean different things:

    - **llama.cpp** — `ctx` is the per-request window and the engine is launched
      with `-c = ctx × parallel`, so the budget is the product (contract "A").
    - **vLLM** — `--max-model-len` *is* the per-request window, and `parallel`
      becomes `--max-num-seqs`. The KV pool is sized by `gpu_memory_utilization`,
      not by `ctx × seqs`, so multiplying over-states it by the batch size.

  Multiplying unconditionally was only ever safe for vLLM because the agent
  reported `parallel: nil`; it now falls back to the configured `--max-num-seqs`,
  so the distinction has to be explicit.
  """
  @spec ctx_total(engine(), pos_integer() | nil, pos_integer() | nil) :: pos_integer() | nil
  def ctx_total(_engine, nil, _parallel), do: nil
  def ctx_total(@vllm, ctx, _parallel), do: ctx
  def ctx_total(_llama_cpp_or_unknown, ctx, parallel), do: ctx * (parallel || 1)

  @doc """
  Whether VRAM cost can be calibrated per KV token for this engine.

  `Airo.Agents.Capacity.per_ctx_mb/3` derives `(vram_used − weights) / ctx_total`
  from live telemetry. vLLM has no `ctx_total` to divide by — it owns paged-KV
  batching internally and reports the field `nil` — and its KV pool is
  pre-allocated to a VRAM *fraction* rather than growing with the context, so the
  per-token model doesn't describe it even in principle.

  This is the difference between "not measured yet" and "not measurable this
  way", which the UI has to say differently.
  """
  @spec calibratable?(engine()) :: boolean()
  def calibratable?(@vllm), do: false
  def calibratable?(_llama_cpp_or_unknown), do: true

  @doc """
  Whether the engine applies sampling knobs (temperature, top-p, the penalties)
  as launch-time server defaults.

  llama-server takes all of them as flags. The vLLM adapter maps **none**, on
  purpose: vLLM's own whitelist is narrow, and per-request params override server
  defaults anyway — so sampling belongs on the Deployment's request defaults, not
  the launch profile. Offering the knobs on a vLLM slot invites an operator to
  set a value that is silently discarded.
  """
  @spec honors_sampling?(engine()) :: boolean()
  def honors_sampling?(@vllm), do: false
  def honors_sampling?(_llama_cpp_or_unknown), do: true

  @doc """
  Whether the engine can spread one load across hosts (`nnodes` / tensor
  parallelism). vLLM only — llama.cpp has no multi-node story here, so the
  cluster knobs are noise on a GGUF slot.
  """
  @spec clusterable?(engine()) :: boolean()
  def clusterable?(@vllm), do: true
  def clusterable?(_llama_cpp_or_unknown), do: false

  @doc """
  The adapter whose `Airo.LocalProvider` implementation fits this engine, or
  `nil` when it has none.

  Agent-managed slots are all `adapter_type: :openai`, which resolves to
  `Airo.Adapters.OpenAICompatible` — no `LocalProvider` at all. So a vLLM slot
  Airo manages used to get none of the `/metrics` and `max_model_len` reporting
  that an *external* vLLM provider gets, purely because of who manages it. This
  maps a managed slot back to the right module.

  llama.cpp has no entry: llama-server exposes no catalog Airo consumes, so
  those slots keep the previous (empty) behaviour rather than being pointed at
  an adapter that would query the wrong endpoints.
  """
  @spec local_provider(engine()) :: module() | nil
  def local_provider(@vllm), do: Airo.Adapters.VLLM
  def local_provider(_none), do: nil

  @doc "Human label for an engine, for the UI."
  @spec label(engine()) :: String.t()
  def label(@llama_cpp), do: "llama.cpp"
  def label(@vllm), do: "vLLM"
  def label(nil), do: "unknown"
  def label(other), do: to_string(other)

  @doc "The engine string for llama.cpp."
  def llama_cpp, do: @llama_cpp

  @doc "The engine string for vLLM."
  def vllm, do: @vllm
end
