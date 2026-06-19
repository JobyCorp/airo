defmodule Airo.Routing.ClassifierTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.Alias
  alias Airo.Routing.Classifier

  # An Infinity classify deployment + a `prompt-class` alias pointing at it.
  defp seed_classifier do
    {:ok, provider} =
      Config.create_provider(%{
        name: "inf-#{System.unique_integer([:positive])}",
        adapter_type: :infinity,
        base_url: "http://inf:7997",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "deberta-zeroshot",
        capabilities: [:classify]
      })

    {:ok, _alias} =
      Config.create_alias(%{
        name: "prompt-class",
        capability: :classify,
        strategy: :priority,
        candidates: [%{deployment_id: deployment.id, weight: 100, priority: 0}]
      })

    :ok
  end

  # Configure the system classifier (S16) — the classifier now reads this, not the
  # alias. Defaults to the Infinity backend pointing at `prompt-class`.
  defp set_routing(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          backend: :infinity,
          classifier: "prompt-class",
          input: :last_user,
          hypothesis_template: "This request requires {}.",
          labels: [
            %{
              "label" => "multi-step reasoning, math, or analysis",
              "class" => "deep",
              "min" => 0.5
            }
          ],
          default_class: "edge",
          timeout_ms: 200
        },
        overrides
      )

    {:ok, _} = Config.update_routing_setting(attrs)
    :ok
  end

  # A routed alias struct — only `router`/`router_mode` matter now; the classifier
  # config lives in the system setting.
  defp routed,
    do: %Alias{name: "chat", capability: :chat, router: :classify, router_mode: :enforce}

  defp params(text), do: %{"messages" => [%{"role" => "user", "content" => text}]}

  # Stub /classify so every input row gets the same `entailment` score. `order`
  # controls whether entailment is the first or second label in the row.
  defp stub_entailment(score, order \\ :entailment_first) do
    Req.Test.stub(Airo.TestStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      inputs = Jason.decode!(raw)["input"]

      pair = fn ->
        e = %{"label" => "entailment", "score" => score}
        n = %{"label" => "not_entailment", "score" => Float.round(1.0 - score, 4)}
        if order == :entailment_first, do: [e, n], else: [n, e]
      end

      rows = Enum.map(inputs, fn _ -> pair.() end)
      Req.Test.json(conn, %{"object" => "classify", "data" => rows})
    end)
  end

  describe "class_for/2" do
    test "routes to deep when entailment clears the threshold" do
      seed_classifier()
      set_routing()
      stub_entailment(0.9)

      assert {:ok, "deep", scores} =
               Classifier.class_for(routed(), params("prove this theorem step by step"))

      assert scores["deep"] >= 0.5
    end

    test "falls back to default_class when nothing crosses" do
      seed_classifier()
      set_routing()
      stub_entailment(0.1)
      assert {:ok, "edge", _scores} = Classifier.class_for(routed(), params("hello there"))
    end

    test "highest-tier-first: first label over min wins when several cross" do
      seed_classifier()

      set_routing(%{
        labels: [
          %{"label" => "multi-file coding", "class" => "cloud", "min" => 0.6},
          %{"label" => "reasoning", "class" => "deep", "min" => 0.5}
        ]
      })

      stub_entailment(0.9)

      assert {:ok, "cloud", _scores} = Classifier.class_for(routed(), params("edit these files"))
    end

    test "reads entailment by label, not position" do
      seed_classifier()
      set_routing()
      stub_entailment(0.9, :entailment_last)

      assert {:ok, "deep", _scores} =
               Classifier.class_for(routed(), params("analyze the tradeoffs"))
    end

    test ":skip when there is no user text" do
      seed_classifier()
      set_routing()

      assert :skip =
               Classifier.class_for(routed(), %{
                 "messages" => [%{"role" => "system", "content" => "x"}]
               })

      assert :skip = Classifier.class_for(routed(), params("   "))
    end

    test "{:error, :bad_config} when the system classifier is unconfigured (no classifier)" do
      # The migration's default row has a nil classifier ⇒ unusable for :infinity.
      assert {:error, :bad_config} = Classifier.class_for(routed(), params("hi"))
    end

    test "{:error, :bad_config} when the classifier alias is missing" do
      set_routing()
      # set_routing names "prompt-class" but seed_classifier/0 wasn't called.
      assert {:error, :bad_config} = Classifier.class_for(routed(), params("hi"))
    end

    test "{:error, _} on an upstream error" do
      seed_classifier()
      set_routing()
      Req.Test.stub(Airo.TestStub, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
      assert {:error, _} = Classifier.class_for(routed(), params("hi"))
    end

    test "{:error, :timeout} when the classifier exceeds the budget" do
      seed_classifier()
      set_routing(%{timeout_ms: 10})

      Req.Test.stub(Airo.TestStub, fn conn ->
        Process.sleep(80)
        Req.Test.json(conn, %{"object" => "classify", "data" => []})
      end)

      assert {:error, :timeout} = Classifier.class_for(routed(), params("hi"))
    end
  end
end
