defmodule Airo.Routing.LocalClassifierTest do
  # Exercises the real bundled ONNX artifact (priv/models/, gitignored). Tagged
  # :model so a CI box without the artifact can `--exclude model` (or run
  # `mix airo.fetch_model nvidia-prompt-task-complexity` first).
  use ExUnit.Case, async: true
  @moduletag :model

  alias Airo.Config.Alias
  alias Airo.Routing.{Classifier, LocalClassifier}

  @model "nvidia-prompt-task-complexity"
  # Recommended routing weighting from the §10 calibration (constraint+reasoning,
  # domain excluded as the topic-trap). Deep threshold 0.20.
  @weights %{
    "constraint" => 0.55,
    "reasoning" => 0.35,
    "creativity" => 0.05,
    "contextual_knowledge" => 0.05
  }

  @reverse "Write a Python function that reverses a string."
  @refactor "Refactor the auth module across these three files (auth.ex, token.ex, session.ex) to use the new TokenStore, updating all call sites and tests."

  setup_all do
    {:ok, _state} = LocalClassifier.load_model(@model)
    :ok
  end

  defp ortex_config(overrides \\ %{}) do
    Map.merge(
      %{
        model: @model,
        timeout_ms: 5000,
        score: @weights,
        labels: [%{label: nil, class: "deep", min: 0.20}],
        default_class: "edge"
      },
      overrides
    )
  end

  describe "score/2 (real ONNX, deterministic)" do
    test "trivial code scores low; multi-file work scores high (graded, not binary)" do
      assert {:ok, low} = LocalClassifier.score(ortex_config(), @reverse)
      assert {:ok, high} = LocalClassifier.score(ortex_config(), @refactor)

      assert_in_delta low["deep"], 0.1034, 0.01
      assert_in_delta high["deep"], 0.3827, 0.01
      # The whole point: both are code, graded by difficulty.
      assert low["deep"] < high["deep"]
    end

    test "carries shadow-log diagnostics (overall, dims, task)" do
      assert {:ok, scores} = LocalClassifier.score(ortex_config(), @reverse)
      assert_in_delta scores["_overall"], 0.19855, 0.01
      assert scores["_task"] == "Code Generation"
      assert %{"constraint" => _, "reasoning" => _, "domain_knowledge" => _} = scores["_dims"]
    end

    test ~s(score: "overall" reads the model's native weighted score) do
      assert {:ok, scores} = LocalClassifier.score(ortex_config(%{score: :overall}), @reverse)
      assert_in_delta scores["deep"], 0.19855, 0.01
    end

    test "duplicates the score under every tier label's class" do
      labels = [%{label: nil, class: "cloud", min: 0.7}, %{label: nil, class: "deep", min: 0.2}]
      assert {:ok, scores} = LocalClassifier.score(ortex_config(%{labels: labels}), @refactor)
      assert scores["cloud"] == scores["deep"]
    end

    test "fail-open: unknown model ⇒ {:error, :model_unavailable}" do
      assert {:error, :model_unavailable} =
               LocalClassifier.score(ortex_config(%{model: "does-not-exist"}), @reverse)
    end
  end

  describe "Classifier.class_for/2 dispatch (backend: :ortex)" do
    defp routed_ortex(overrides \\ %{}) do
      config =
        Map.merge(
          %{
            "backend" => "ortex",
            "model" => @model,
            "input" => "last_user",
            "score" => @weights,
            "labels" => [%{"class" => "deep", "min" => 0.20}],
            "default_class" => "edge",
            "timeout_ms" => 5000
          },
          overrides
        )

      %Alias{name: "chat", capability: :chat, router: :classify, router_config: config}
    end

    defp params(text), do: %{"messages" => [%{"role" => "user", "content" => text}]}

    test "routes edge/deep on CPU with no Infinity classifier seeded (no HTTP)" do
      # No classifier alias exists and no Req stub is set — a successful decision
      # proves the ortex path ran in-process, not the Infinity HTTP path.
      assert {:ok, "edge", _scores} = Classifier.class_for(routed_ortex(), params(@reverse))
      assert {:ok, "deep", _scores} = Classifier.class_for(routed_ortex(), params(@refactor))
    end

    test "{:error, :bad_config} when ortex config omits :model" do
      alias_ = routed_ortex(%{"model" => nil})
      assert {:error, :bad_config} = Classifier.class_for(alias_, params(@reverse))
    end

    test ":skip when there is no user text (shared extraction path)" do
      assert :skip = Classifier.class_for(routed_ortex(), params("   "))
    end
  end
end
