defmodule AiroWeb.AgentLiveTest do
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.Config

  defp agent_with_slot(host_id \\ "test-host") do
    {:ok, agent} =
      Config.create_agent(%{
        host_id: host_id,
        control_url: "http://#{host_id}:4400",
        version: "0.1.0"
      })

    {:ok, provider} =
      Config.create_provider(%{
        name: "#{host_id}:8081",
        adapter_type: :openai,
        base_url: "http://#{host_id}:8081/v1",
        auth_kind: :none,
        agent_id: agent.id
      })

    {agent, provider}
  end

  describe "forgetting an orphaned agent" do
    test "removes a host that is offline and manages nothing", %{conn: conn} do
      {:ok, gone} =
        Config.create_agent(%{host_id: "renamed-away", control_url: "http://old:4400"})

      {:ok, view, _html} = live(conn, ~p"/admin/agents")
      row = ~s{[phx-click="delete_agent"][phx-value-id="#{gone.id}"]}
      assert has_element?(view, row)

      html = view |> element(row) |> render_click()

      # The row is gone from the roster (the host_id still appears in the
      # confirmation flash, so match on the row rather than the bare name).
      refute has_element?(view, row)
      assert html =~ "Forgot agent renamed-away"
      assert Config.get_agent_by_host_id("renamed-away") == nil
    end

    test "an empty slot doesn't block it — it goes too", %{conn: conn} do
      # Nothing routes to a slot with no deployments, so making the operator go
      # delete it by hand on /admin/providers first was a dead end, not a guard.
      {agent, provider} = agent_with_slot("has-empty-slot")

      {:ok, view, _html} = live(conn, ~p"/admin/agents")

      button = element(view, ~s{[phx-click="delete_agent"][phx-value-id="#{agent.id}"]})
      refute render(button) =~ "disabled"
      assert render(button) =~ "and its 1 empty slot"

      html = render_click(view, "delete_agent", %{"id" => to_string(agent.id)})

      assert html =~ "Forgot agent has-empty-slot"
      assert Config.get_agent_by_host_id("has-empty-slot") == nil
      # Removed, not left behind with a null agent_id (the FK is nilify_all).
      assert_raise Ecto.NoResultsError, fn -> Config.get_provider!(provider.id) end
    end

    test "won't let you strand a slot a deployment routes to", %{conn: conn} do
      {agent, provider} = agent_with_slot("has-bound-slot")

      {:ok, _} =
        Config.create_deployment(%{
          provider_id: provider.id,
          model_name: "qwen3-30b",
          capabilities: [:chat]
        })

      {:ok, view, _html} = live(conn, ~p"/admin/agents")

      button = element(view, ~s{[phx-click="delete_agent"][phx-value-id="#{agent.id}"]})
      assert render(button) =~ "disabled"
      assert render(button) =~ "1 slot(s) with deployments"

      # Disabled in the markup AND refused if the event is sent anyway.
      html = render_click(view, "delete_agent", %{"id" => to_string(agent.id)})

      assert html =~ "1 slot(s) with deployments"
      assert html =~ "unmanaged providers"
      assert Config.get_agent_by_host_id("has-bound-slot")
      assert Config.get_provider!(provider.id).agent_id == agent.id
    end
  end

  test "a 'resync' broadcast on the agent topic doesn't crash the view", %{conn: conn} do
    {agent, _provider} = agent_with_slot()

    {:ok, view, _html} = live(conn, ~p"/admin/agents/#{agent.id}")

    # Resync fans out on the channel topic the view also subscribes to (for
    # presence). The view must ignore it, not crash on an unmatched handle_info.
    AiroWeb.Endpoint.broadcast("agent:#{agent.host_id}", "resync", %{})

    assert render(view) =~ agent.host_id
    assert Process.alive?(view.pid)
  end

  test "a slot-state broadcast re-renders the resident model from SlotState", %{conn: conn} do
    {agent, provider} = agent_with_slot("slotty")

    {:ok, view, _html} = live(conn, ~p"/admin/agents/#{agent.id}")
    refute render(view) =~ "Qwen-Test"

    Airo.Agents.SlotState.put(provider.id, %{
      resident_model: "Qwen-Test",
      revision: "abc123",
      status: :up
    })

    Phoenix.PubSub.broadcast(
      Airo.PubSub,
      Airo.Agents.Ingest.slots_topic(agent.host_id),
      {:agent_slots, agent.host_id}
    )

    assert render(view) =~ "Qwen-Test"
  end
end
