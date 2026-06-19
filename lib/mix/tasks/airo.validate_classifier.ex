defmodule Mix.Tasks.Airo.ValidateClassifier do
  @shortdoc "Validate the local ONNX classifier on CPU: decision parity + latency"

  @moduledoc """
  Run the §10 calibration prompt set through the `:ortex` backend on CPU, assert
  the edge-vs-deep decision matches expectations for all prompts, and report
  single-inference latency (p50/p95). This is the on-CPU end-to-end proof S15
  exists to produce (DESIGN-local-classifier.md §5 T4 / §10).

      mix airo.validate_classifier

  Exits non-zero if any prompt misroutes, so it is usable as a gate.
  """

  use Mix.Task

  alias Airo.Routing.LocalClassifier

  @model "nvidia-prompt-task-complexity"
  @threshold 0.20
  @weights %{
    "constraint" => 0.55,
    "reasoning" => 0.35,
    "creativity" => 0.05,
    "contextual_knowledge" => 0.05
  }

  # The §10 set: 4 edge + 3 deep, including the two code-nuance cases (#4 vs #5).
  @prompts [
    {"Thanks, that's really helpful!", :edge},
    {"Summarize this short email in one sentence: \"Hi team, the Q3 sync moved to Thursday 2pm, same room. Please update your calendars.\"",
     :edge},
    {"What's the capital of France?", :edge},
    {"Write a Python function that reverses a string.", :edge},
    {"Refactor the auth module across these three files (auth.ex, token.ex, session.ex) to use the new TokenStore, updating all call sites and tests.",
     :deep},
    {"A train leaves Boston at 60 mph, another leaves NYC at 75 mph toward each other, 215 miles apart. When do they meet? Show your work.",
     :deep},
    {"Compare optimistic vs pessimistic locking for a high-contention inventory table, with trade-offs and when to use each.",
     :deep}
  ]

  @config %{
    model: @model,
    timeout_ms: 5000,
    score: @weights,
    labels: [%{label: nil, class: "deep", min: @threshold}]
  }

  @impl true
  def run(_argv) do
    case LocalClassifier.load_model(@model) do
      {:ok, _} ->
        :ok

      :unavailable ->
        Mix.raise("model #{@model} unavailable — run `mix airo.fetch_model #{@model}`")
    end

    # Warm a few times so the latency sample excludes cold-start.
    Enum.each(1..3, fn _ -> score!(elem(hd(@prompts), 0)) end)

    Mix.shell().info("score = #{inspect(@weights)}  ·  deep threshold = #{@threshold}\n")
    Mix.shell().info(String.pad_trailing("decision", 10) <> "score   expect   prompt")

    results = Enum.map(@prompts, &check/1)
    misses = Enum.count(results, &(&1 == :miss))

    latencies = measure_latency()
    report_latency(latencies)

    if misses == 0 do
      Mix.shell().info("\n✓ decision parity: #{length(@prompts)}/#{length(@prompts)}")
    else
      Mix.raise("decision parity FAILED: #{misses}/#{length(@prompts)} misrouted")
    end
  end

  defp check({prompt, expected}) do
    {score, decision} = decide(prompt)
    ok? = decision == expected
    mark = if ok?, do: "OK ", else: "XX "

    Mix.shell().info(
      "#{mark}" <>
        String.pad_trailing(to_string(decision), 7) <>
        String.pad_trailing(:erlang.float_to_binary(score, decimals: 3), 8) <>
        String.pad_trailing(to_string(expected), 9) <>
        snippet(prompt)
    )

    if ok?, do: :ok, else: :miss
  end

  defp decide(prompt) do
    scores = score!(prompt)
    s = Map.get(scores, "deep")
    {s, if(s >= @threshold, do: :deep, else: :edge)}
  end

  defp score!(prompt) do
    {:ok, scores} = LocalClassifier.score(@config, prompt)
    scores
  end

  defp measure_latency do
    prompts = Enum.map(@prompts, &elem(&1, 0))

    for _ <- 1..30, p <- prompts do
      {us, _} = :timer.tc(fn -> score!(p) end)
      us / 1000.0
    end
    |> Enum.sort()
  end

  defp report_latency(sorted) do
    n = length(sorted)
    p = fn q -> Enum.at(sorted, min(n - 1, round(q * n))) end

    Mix.shell().info(
      "\nlatency (score/2, CPU, n=#{n}):  " <>
        "p50 #{fmt(p.(0.50))}ms · p95 #{fmt(p.(0.95))}ms · " <>
        "min #{fmt(hd(sorted))}ms · max #{fmt(List.last(sorted))}ms"
    )
  end

  defp fmt(ms), do: :erlang.float_to_binary(ms, decimals: 1)
  defp snippet(p), do: p |> String.slice(0, 48) |> String.replace("\n", " ")
end
