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

  defp deployment(provider) do
    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "qwen3-30b",
        capabilities: [:chat]
      })

    deployment
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

  describe "delete_agent/2 with cascade_empty_slots" do
    test "takes the empty slots with the agent" do
      agent = agent()
      provider = slot(agent)

      assert {:ok, _} = Config.delete_agent(agent, cascade_empty_slots: true)

      assert Config.get_agent_by_host_id("gone-host") == nil
      # Removed outright, not nilified into an unmanaged provider — which is the
      # only thing the arity-1 refusal was ever protecting against.
      assert_raise Ecto.NoResultsError, fn -> Config.get_provider!(provider.id) end
    end

    test "still refuses a slot a deployment routes to" do
      agent = agent()
      bound = slot(agent, 8081)
      deployment(bound)

      assert {:error, {:has_providers, 1}} = Config.delete_agent(agent, cascade_empty_slots: true)
      assert Config.get_agent_by_host_id("gone-host")
      assert Config.get_provider!(bound.id).agent_id == agent.id
    end

    test "counts only the slots that are actually in the way" do
      agent = agent()
      slot(agent, 8081)
      slot(agent, 8082)
      deployment(slot(agent, 8083))

      assert {:error, {:has_providers, 1}} = Config.delete_agent(agent, cascade_empty_slots: true)
    end

    test "a bound slot keeps the empty ones too — the delete is all or nothing" do
      agent = agent()
      empty = slot(agent, 8081)
      deployment(slot(agent, 8082))

      assert {:error, {:has_providers, 1}} = Config.delete_agent(agent, cascade_empty_slots: true)
      assert Config.get_provider!(empty.id)
    end

    test "the default is still the strict refusal" do
      agent = agent()
      provider = slot(agent)

      assert {:error, {:has_providers, 1}} = Config.delete_agent(agent)
      assert Config.get_provider!(provider.id)
    end
  end
end
