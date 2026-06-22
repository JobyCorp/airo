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
