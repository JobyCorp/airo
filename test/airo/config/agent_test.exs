defmodule Airo.Config.AgentTest do
  @moduledoc """
  Deleting an agent whose host is gone — a renamed or retired box that would
  otherwise sit in the roster as permanently offline.
  """
  use Airo.DataCase, async: true

  alias Airo.{Agents, Config}

  defp agent(host_id \\ "gone-host") do
    {:ok, agent} =
      Config.create_agent(%{host_id: host_id, control_url: "http://#{host_id}:4400"})

    agent
  end

  defp slot(agent, port \\ 8081) do
    {:ok, provider} =
      Config.create_provider(%{
        name: "#{agent.host_id}:#{port}",
        adapter_type: :openai,
        base_url: "http://#{agent.host_id}:#{port}/v1",
        auth_kind: :none,
        agent_id: agent.id
      })

    provider
  end

  describe "delete_agent/1" do
    test "removes an agent that manages nothing" do
      agent = agent()

      assert {:ok, _} = Config.delete_agent(agent)
      assert Config.get_agent_by_host_id("gone-host") == nil
    end

    test "refuses while it still manages slots" do
      agent = agent()
      slot(agent)

      assert {:error, {:has_providers, 1}} = Config.delete_agent(agent)
      assert Config.get_agent_by_host_id("gone-host")
    end

    test "reports how many slots are in the way" do
      agent = agent()
      slot(agent, 8081)
      slot(agent, 8082)

      assert {:error, {:has_providers, 2}} = Config.delete_agent(agent)
    end

    test "the refusal is what stops slots becoming unmanaged providers" do
      # providers.agent_id is `on_delete: :nilify_all`, so an unguarded delete
      # leaves the slot behind with a null agent_id — indistinguishable from an
      # external provider, probed by the prober and still routable, under a
      # host:port name nothing manages any more.
      agent = agent()
      provider = slot(agent)

      assert {:error, {:has_providers, 1}} = Config.delete_agent(agent)

      assert Config.get_provider!(provider.id).agent_id == agent.id
    end

    test "deleting is possible again once the slots are gone" do
      agent = agent()
      provider = slot(agent)

      assert {:error, {:has_providers, 1}} = Config.delete_agent(agent)

      Config.delete_provider(provider)

      assert {:ok, _} = Config.delete_agent(agent)
    end

    test "a host that reconnects simply registers afresh" do
      # Nothing is lost by forgetting a host: `register/2` upserts by host_id, so
      # a box that comes back builds a new row rather than resurrecting state.
      agent = agent("returning")
      assert {:ok, _} = Config.delete_agent(agent)

      assert {:ok, %{agent: fresh}} =
               Agents.register("returning", %{
                 "agent" => %{"control_url" => "http://returning:4400"},
                 "slots" => []
               })

      assert fresh.host_id == "returning"
      refute fresh.id == agent.id
    end
  end
end
