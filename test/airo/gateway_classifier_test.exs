defmodule Airo.GatewayClassifierTest do
  # async: false → DataCase shares the sandbox (the detached shadow task can reach
  # the DB) and we can safely raise the global Logger level to capture the T5 event.
  use Airo.DataCase, async: false

  import ExUnit.CaptureLog

  alias Airo.Config
  alias Airo.Gateway

  @router_config %{
    "mode" => "shadow",
    "classifier" => "prompt-class",
    "input" => "last_user",
    "hypothesis_template" => "This request requires {}.",
    "labels" => [
      %{"label" => "multi-step reasoning, math, or analysis", "class" => "deep", "min" => 0.5}
    ],
    "default_class" => "edge",
    "timeout_ms" => 200
  }

  setup do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)
    :ok
  end

  defp openai_provider do
    {:ok, p} =
      Config.create_provider(%{
        name: "oai-#{System.unique_integer([:positive])}",
        adapter_type: :openai,
        base_url: "http://up/v1",
        auth_kind: :none
      })

    p
  end

  defp chat_deployment(provider, model, class) do
    {:ok, d} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: model,
        capabilities: [:chat],
        class: class
      })

    d
  end

  # edge + deep chat deployments, an Infinity classifier, a `prompt-class` alias,
  # and a routed `chat` alias in `mode`. Returns a client key.
  defp seed(mode) do
    p = openai_provider()
    edge = chat_deployment(p, "edge-model", :edge)
    deep = chat_deployment(p, "deep-model", :deep)

    {:ok, inf} =
      Config.create_provider(%{
        name: "inf-#{System.unique_integer([:positive])}",
        adapter_type: :infinity,
        base_url: "http://inf:7997",
        auth_kind: :none
      })

    {:ok, clf} =
      Config.create_deployment(%{
        provider_id: inf.id,
        model_name: "deberta",
        capabilities: [:classify]
      })

    {:ok, _} =
      Config.create_alias(%{
        name: "prompt-class",
        capability: :classify,
        strategy: :priority,
        candidates: [%{deployment_id: clf.id, weight: 100, priority: 0}]
      })

    {:ok, _} =
      Config.create_alias(%{
        name: "chat",
        capability: :chat,
        strategy: :priority,
        router: :classify,
        router_config: Map.put(@router_config, "mode", mode),
        candidates: [
          %{deployment_id: edge.id, weight: 100, priority: 0},
          %{deployment_id: deep.id, weight: 100, priority: 1}
        ]
      })

    {:ok, key} =
      Config.mint_client_key(%{
        name: "k-#{System.unique_integer([:positive])}",
        allowed_aliases: ["*"]
      })

    key
  end

  defp stub_entailment(score) do
    Req.Test.stub(Airo.TestStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      rows =
        Enum.map(Jason.decode!(raw)["input"], fn _ ->
          [
            %{"label" => "entailment", "score" => score},
            %{"label" => "not_entailment", "score" => Float.round(1.0 - score, 4)}
          ]
        end)

      Req.Test.json(conn, %{"object" => "classify", "data" => rows})
    end)
  end

  defp classes(plan), do: Enum.map(plan.attempts, & &1.deployment.class)

  # Shadow spawns a detached task on the shared Task.Supervisor; drain it before
  # the test ends so it can't outlive the sandbox (this file is sync, so the
  # supervisor's only children here are ours).
  defp drain_shadow_tasks(tries \\ 100) do
    case Task.Supervisor.children(Airo.Usage.TaskSupervisor) do
      [] -> :ok
      _ when tries > 0 -> Process.sleep(5) && drain_shadow_tasks(tries - 1)
      _ -> :ok
    end
  end

  defp chat(text),
    do: %{"model" => "chat", "messages" => [%{"role" => "user", "content" => text}]}

  describe "enforce mode" do
    test "filters candidates to the predicted class and logs the event" do
      key = seed("enforce")
      stub_entailment(0.9)

      log =
        capture_log(fn ->
          assert {:ok, plan} =
                   Gateway.resolve(chat("prove this theorem step by step"), key, :chat)

          assert classes(plan) == [:deep]
        end)

      assert log =~ "gateway.route.classified"
    end

    test "low confidence applies default_class (edge)" do
      key = seed("enforce")
      stub_entailment(0.1)

      assert {:ok, plan} = Gateway.resolve(chat("hi there"), key, :chat)
      assert classes(plan) == [:edge]
    end

    test "a classifier error applies no class filter (full candidate set)" do
      key = seed("enforce")
      Req.Test.stub(Airo.TestStub, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      assert {:ok, plan} = Gateway.resolve(chat("prove this theorem"), key, :chat)
      assert classes(plan) == [:edge, :deep]
    end
  end

  describe "shadow mode" do
    test "serves the priority head and does not apply the predicted class" do
      key = seed("shadow")
      stub_entailment(0.9)

      assert {:ok, plan} = Gateway.resolve(chat("prove this theorem"), key, :chat)
      # Classifier predicts :deep, but shadow never filters → priority order.
      assert classes(plan) == [:edge, :deep]

      drain_shadow_tasks()
    end
  end

  describe "caller precedence and opt-out" do
    test "an explicit route.class skips the classifier entirely" do
      key = seed("enforce")
      test_pid = self()

      Req.Test.stub(Airo.TestStub, fn conn ->
        send(test_pid, :classifier_called)
        Req.Test.json(conn, %{"object" => "classify", "data" => []})
      end)

      req = Map.put(chat("prove this theorem"), "route", %{"class" => "edge"})

      assert {:ok, plan} = Gateway.resolve(req, key, :chat)
      assert classes(plan) == [:edge]
      refute_received :classifier_called
    end

    test "a router: :none alias is unaffected (non-regression)" do
      p = openai_provider()
      e = chat_deployment(p, "plain-edge", :edge)
      d = chat_deployment(p, "plain-deep", :deep)

      {:ok, _} =
        Config.create_alias(%{
          name: "plain",
          capability: :chat,
          strategy: :priority,
          candidates: [
            %{deployment_id: e.id, weight: 100, priority: 0},
            %{deployment_id: d.id, weight: 100, priority: 1}
          ]
        })

      {:ok, key} =
        Config.mint_client_key(%{
          name: "k-#{System.unique_integer([:positive])}",
          allowed_aliases: ["*"]
        })

      req = %{
        "model" => "plain",
        "messages" => [%{"role" => "user", "content" => "prove this theorem"}]
      }

      assert {:ok, plan} = Gateway.resolve(req, key, :chat)
      assert classes(plan) == [:edge, :deep]
    end
  end
end
