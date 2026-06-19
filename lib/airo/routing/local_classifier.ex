defmodule Airo.Routing.LocalClassifier do
  @moduledoc """
  On-CPU routing classifier backend (S15) — runs an ONNX complexity model via
  Ortex, in-process on the BEAM, with **zero GPU / Infinity call**.

  This is the `backend: :ortex` half of `Airo.Routing.Classifier.score/2`. It
  returns the same `{:ok, %{class => score}}` shape `Classifier.decide/2` already
  consumes, where `score` is a **graded 0–1 difficulty** value (not a topic
  entailment). The model (NVIDIA `prompt-task-and-complexity-classifier`,
  DeBERTa-v3-base) emits per-dimension complexity scores in a **single forward
  pass** over the bare prompt; the routing score is a configurable weighted
  combination of those dims (the `router_config["score"]` knob), and
  `decide/2` thresholds it into a tier ladder. The map also carries `_overall`,
  `_dims`, and `_task` diagnostics for the shadow-log (decide ignores `_`-keys).

  **Load once:** the `Holder` GenServer loads the ORT session + tokenizer at boot
  into `:persistent_term` and warms it; per-request `score/2` only encodes + runs.
  **Fail-open:** a missing artifact or a load/inference explosion yields
  `{:error, :model_unavailable}` (or a bounded `{:error, _}`) → the gateway leaves
  routing untouched. See DESIGN-local-classifier.md.

  > Thread pinning: Ortex 0.1.10 does not expose ORT intra/inter-op thread counts,
  > so we rely on `Ortex.run` being a dirty NIF (won't block normal schedulers).
  > Pin threads (OMP env / Ortex PR) before any production/enforce cutover.
  """

  require Logger

  # `complexity_dims` output order (verified against the export's contract.json
  # and the calibration dump — see DESIGN-local-classifier.md §10).
  @dims ~w(creativity reasoning constraint domain_knowledge contextual_knowledge num_few_shots)

  # `task_type` argmax → label (alphabetical; idx 4 = Code Generation, idx 6 =
  # Open QA, cross-checked against the calibration dump). Diagnostic only.
  @task_labels [
    "Brainstorming",
    "Chatbot",
    "Classification",
    "Closed QA",
    "Code Generation",
    "Extraction",
    "Open QA",
    "Other",
    "Rewrite",
    "Summarization",
    "Text Generation"
  ]

  @default_max_seq 512

  @doc """
  Score `premise` with the model named by `config.model`.

  Returns `{:ok, %{class => score, "_overall" => ..., "_dims" => %{}, "_task" =>
  ...}}` with `score` the graded routing value duplicated under every tier label's
  class; `{:error, :model_unavailable}` if the model didn't load; or a bounded
  `{:error, _}` on timeout / inference failure.
  """
  @spec score(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def score(%{model: model} = config, premise) when is_binary(premise) do
    case :persistent_term.get({__MODULE__, model}, :missing) do
      {:ok, state} -> run_bounded(config.timeout_ms, fn -> infer(config, state, premise) end)
      _ -> {:error, :model_unavailable}
    end
  end

  ## Holder — loads the session + tokenizer once at boot into :persistent_term.

  defmodule Holder do
    @moduledoc false
    use GenServer
    alias Airo.Routing.LocalClassifier

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      :airo
      |> Application.get_env(LocalClassifier, [])
      |> Keyword.get(:models, [])
      |> Enum.each(&LocalClassifier.load_model/1)

      {:ok, %{}}
    end
  end

  @doc """
  Load `name` (a dir under `priv/models/`) into `:persistent_term`. Stores
  `{:ok, state}` on success or `:unavailable` on any failure — never raises, so a
  missing/broken artifact degrades to fail-open rather than crashing boot. Public
  so tests can load on demand.
  """
  @spec load_model(String.t()) :: {:ok, map()} | :unavailable
  def load_model(name) do
    dir = Path.join([:code.priv_dir(:airo), "models", name])
    onnx = Path.join(dir, "model.onnx")
    tok_path = Path.join(dir, "tokenizer.json")

    result =
      try do
        if File.exists?(onnx) and File.exists?(tok_path) do
          {:ok, tokenizer} = Tokenizers.Tokenizer.from_file(tok_path)
          tokenizer = Tokenizers.Tokenizer.set_truncation(tokenizer, max_length: max_seq())
          state = %{model: Ortex.load(onnx), tokenizer: tokenizer}
          warmup(state)
          {:ok, state}
        else
          Logger.warning("LocalClassifier: artifact missing for #{name} at #{dir}")
          :unavailable
        end
      rescue
        e ->
          Logger.warning("LocalClassifier: load failed for #{name}: #{inspect(e)}")
          :unavailable
      catch
        kind, reason ->
          Logger.warning("LocalClassifier: load #{kind} for #{name}: #{inspect(reason)}")
          :unavailable
      end

    :persistent_term.put({__MODULE__, name}, result)
    result
  end

  defp warmup(state) do
    _ = encode_and_run(state, "warmup")
    :ok
  rescue
    _ -> :ok
  end

  ## Inference

  defp infer(config, state, premise) do
    {dims, overall, task_probs} = encode_and_run(state, premise)
    dim_list = Nx.to_flat_list(dims)
    overall_val = overall |> Nx.to_flat_list() |> hd()
    score = routing_score(config.score, dim_list, overall_val)

    diagnostics = %{
      "_overall" => round5(overall_val),
      "_dims" => @dims |> Enum.zip(Enum.map(dim_list, &round5/1)) |> Map.new(),
      "_task" => task_label(task_probs)
    }

    scores = Map.new(config.labels, fn label -> {label.class, score} end)
    {:ok, Map.merge(diagnostics, scores)}
  end

  defp encode_and_run(%{model: model, tokenizer: tokenizer}, text) do
    {:ok, enc} = Tokenizers.Tokenizer.encode(tokenizer, text)
    ids = Tokenizers.Encoding.get_ids(enc)
    mask = Tokenizers.Encoding.get_attention_mask(enc)
    Ortex.run(model, {Nx.tensor([ids], type: :s64), Nx.tensor([mask], type: :s64)})
  end

  # `:overall` reads the model's own weighted score; a weight map computes the
  # routing-specific linear combination over `complexity_dims` (the §4 knob).
  defp routing_score(:overall, _dims, overall_val), do: overall_val

  defp routing_score(weights, dims, _overall_val) when is_map(weights) do
    @dims
    |> Enum.zip(dims)
    |> Enum.reduce(0.0, fn {name, val}, acc -> acc + Map.get(weights, name, 0.0) * val end)
  end

  defp task_label(task_probs) do
    idx = task_probs |> Nx.to_flat_list() |> Enum.with_index() |> Enum.max() |> elem(1)
    Enum.at(@task_labels, idx, "Unknown")
  end

  defp round5(x), do: Float.round(x * 1.0, 5)

  defp max_seq do
    :airo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_seq, @default_max_seq)
  end

  ## Timeout — bound the inference; never crash the caller (mirrors Classifier).

  defp run_bounded(timeout_ms, fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          e -> {:error, {:exception, e}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end
end
