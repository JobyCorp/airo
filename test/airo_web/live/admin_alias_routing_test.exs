defmodule AiroWeb.AdminAliasRoutingTest do
  @moduledoc """
  The operator-facing classifier-routing editor on the alias page: Save persists,
  but Test (and any non-save submit, e.g. Enter in the prompt field) must never
  overwrite the live config. Guards the intent-dispatch in `routing_submit`.
  """
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.Config

  defp uniq, do: System.unique_integer([:positive])

  defp seed_chat_alias do
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

    {:ok, chat} =
      Config.create_alias(%{
        name: "chat",
        capability: :chat,
        strategy: :priority,
        router: :classify,
        router_config: %{
          "mode" => "shadow",
          "classifier" => "prompt-class",
          "input" => "last_user",
          "hypothesis_template" => "This request requires {}.",
          "default_class" => "edge",
          "timeout_ms" => 200,
          "labels" => [%{"label" => "reasoning", "class" => "deep", "min" => 0.5}]
        },
        candidates: [
          %{deployment_id: edge.id, weight: 100, priority: 0},
          %{deployment_id: deep.id, weight: 100, priority: 1}
        ]
      })

    chat
  end

  defp min_for(name),
    do: Config.get_alias_by_name(name).router_config["labels"] |> hd() |> Map.get("min")

  # Form params with the deep label's threshold overridden to `min`.
  defp form_params(min) do
    %{
      "router" => "classify",
      "rc" => %{
        "mode" => "shadow",
        "classifier" => "prompt-class",
        "input" => "last_user",
        "hypothesis_template" => "This request requires {}.",
        "default_class" => "edge",
        "timeout_ms" => "200",
        "labels" => %{
          "0" => %{"label" => "reasoning", "class" => "deep", "min" => to_string(min)}
        }
      },
      "preview_prompt" => "prove this theorem step by step"
    }
  end

  test "Save persists the config; Test and Enter preview without persisting", %{conn: conn} do
    chat = seed_chat_alias()

    # Stub the classifier so the Test preview can resolve when reachable; the
    # persistence assertions hold regardless of the prediction.
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

    {:ok, view, _html} = live(conn, ~p"/admin/aliases/#{chat.id}/edit")

    # Test (intent=test) → preview only, must NOT persist
    view |> form("#alias-routing-form", form_params(0.7)) |> render_submit(%{"intent" => "test"})
    assert min_for("chat") == 0.5

    # Enter / no submitter → treated as Test, must NOT persist
    view |> form("#alias-routing-form", form_params(0.8)) |> render_submit()
    assert min_for("chat") == 0.5

    # Save (intent=save) → persists
    view |> form("#alias-routing-form", form_params(0.7)) |> render_submit(%{"intent" => "save"})
    assert min_for("chat") == 0.7
  end
end
