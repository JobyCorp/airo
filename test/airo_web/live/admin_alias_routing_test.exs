defmodule AiroWeb.AdminAliasRoutingTest do
  @moduledoc """
  The alias routing section (S16): it only toggles whether the alias uses the
  system classifier (`router`) and the per-alias `router_mode` — the classifier
  itself is configured at /admin/routing. (Replaces the old per-alias config form.)
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

    {:ok, chat} =
      Config.create_alias(%{
        name: "chat-#{uniq()}",
        capability: :chat,
        strategy: :priority,
        candidates: [%{deployment_id: edge.id, weight: 100, priority: 0}]
      })

    chat
  end

  test "turning routing on with enforce persists router + router_mode", %{conn: conn} do
    chat = seed_chat_alias()
    {:ok, view, _html} = live(conn, ~p"/admin/aliases/#{chat.id}/edit")

    view
    |> form("#alias-routing-form", %{"router" => "classify", "router_mode" => "enforce"})
    |> render_submit()

    updated = Config.get_alias_by_name(chat.name)
    assert updated.router == :classify
    assert updated.router_mode == :enforce
  end

  test "turning routing off resets router to :none", %{conn: conn} do
    chat = seed_chat_alias()
    {:ok, _} = Config.update_alias(chat, %{router: :classify, router_mode: :enforce})

    {:ok, view, _html} = live(conn, ~p"/admin/aliases/#{chat.id}/edit")

    view
    |> form("#alias-routing-form", %{"router" => "none", "router_mode" => "shadow"})
    |> render_submit()

    assert Config.get_alias_by_name(chat.name).router == :none
  end
end
