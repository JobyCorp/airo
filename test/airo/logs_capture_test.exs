defmodule Airo.LogsCaptureTest do
  @moduledoc """
  S14 capture (DESIGN-logging-traceability.md, T2): gateway route predictions and
  health transitions are mirrored into `log_events`.
  """
  use Airo.DataCase, async: true

  alias Airo.{Config, Gateway, Health, Logs}

  defp uniq, do: System.unique_integer([:positive])

  describe "health transitions" do
    test "a transition writes a :health log event (level :warning when down)" do
      {:ok, provider} =
        Config.create_provider(%{
          name: "p-#{uniq()}",
          adapter_type: :vllm,
          base_url: "http://x/v1",
          auth_kind: :none
        })

      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: provider.id,
          model_name: "m-#{uniq()}",
          capabilities: [:chat]
        })

      # unknown -> down is a transition
      Health.mark_deployment(deployment, provider, :down, source: :dispatch, reason: "http_503")

      assert [event] = Logs.list(%{"kind" => "health"}, 100)
      assert event.level == :warning
      assert event.deployment_id == deployment.id
      assert event.provider_id == provider.id
      assert event.data["status"] == "down"
      assert event.data["source"] == "dispatch"
      assert event.data["reason"] == "http_503"
    end
  end

  describe "route predictions" do
    setup do
      {:ok, oai} =
        Config.create_provider(%{
          name: "oai-#{uniq()}",
          adapter_type: :openai,
          base_url: "http://up/v1",
          auth_kind: :none
        })

      {:ok, edge} =
        Config.create_deployment(%{
          provider_id: oai.id,
          model_name: "edge-#{uniq()}",
          capabilities: [:chat],
          class: :edge
        })

      {:ok, deep} =
        Config.create_deployment(%{
          provider_id: oai.id,
          model_name: "deep-#{uniq()}",
          capabilities: [:chat],
          class: :deep
        })

      {:ok, inf} =
        Config.create_provider(%{
          name: "inf-#{uniq()}",
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
        Config.update_routing_setting(%{
          backend: :infinity,
          classifier: "prompt-class",
          input: :last_user,
          hypothesis_template: "This request requires {}.",
          default_class: "edge",
          timeout_ms: 200,
          labels: [%{"label" => "reasoning", "class" => "deep", "min" => 0.5}]
        })

      {:ok, chat} =
        Config.create_alias(%{
          name: "chat",
          capability: :chat,
          strategy: :priority,
          router: :classify,
          router_mode: :enforce,
          candidates: [
            %{deployment_id: edge.id, weight: 100, priority: 0},
            %{deployment_id: deep.id, weight: 100, priority: 1}
          ]
        })

      {:ok, key} = Config.mint_client_key(%{name: "k-#{uniq()}", allowed_aliases: ["*"]})

      %{key: key, chat: chat}
    end

    test "an enforce classification writes a :route_prediction log event", %{key: key} do
      Req.Test.stub(Airo.TestStub, fn upstream ->
        Req.Test.json(upstream, %{
          "object" => "classify",
          "data" => [
            [
              %{"label" => "entailment", "score" => 0.9},
              %{"label" => "not_entailment", "score" => 0.1}
            ]
          ]
        })
      end)

      params = %{
        "model" => "chat",
        "messages" => [%{"role" => "user", "content" => "prove this theorem"}]
      }

      assert {:ok, _plan} = Gateway.resolve(params, key, :chat)

      assert [event] = Logs.list(%{"kind" => "route_prediction"}, 100)
      assert event.alias_name == "chat"
      assert event.data["predicted_class"] == "deep"
      assert event.data["applied"] == true
    end
  end
end
