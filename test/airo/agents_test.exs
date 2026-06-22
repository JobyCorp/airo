defmodule Airo.AgentsTest do
  use Airo.DataCase, async: true

  alias Airo.{Agents, Config}

  @host "jobycorp"

  defp payload(slots \\ [%{"port" => 8081, "base_url" => "http://jobycorp:8081/v1"}]) do
    %{
      "agent" => %{
        "control_url" => "http://jobycorp:4400",
        "version" => "0.1.0",
        "gpu" => %{"vram_total_mb" => 32_000}
      },
      "slots" => slots
    }
  end

  test "register/2 upserts the agent and its slot as a managed provider" do
    assert {:ok, %{agent: agent, providers: [provider]}} = Agents.register(@host, payload())

    assert agent.host_id == @host
    assert agent.control_url == "http://jobycorp:4400"
    assert agent.version == "0.1.0"
    assert agent.gpu["vram_total_mb"] == 32_000
    assert agent.last_seen_at

    # The slot is a real serving provider, not the agent — base_url is the engine.
    assert provider.name == "jobycorp:8081"
    assert provider.adapter_type == :openai
    assert provider.base_url == "http://jobycorp:8081/v1"
    assert provider.agent_id == agent.id
  end

  test "register/2 is idempotent and updates on re-register" do
    {:ok, %{agent: a1}} = Agents.register(@host, payload())

    {:ok, %{agent: a2}} =
      Agents.register(@host, %{
        "agent" => %{"control_url" => "http://jobycorp:4400", "version" => "0.2.0"},
        "slots" => [%{"port" => 8081, "base_url" => "http://jobycorp:8081/v1"}]
      })

    assert a1.id == a2.id
    assert a2.version == "0.2.0"
    # A sparse re-register (no gpu) preserves the prior telemetry.
    assert a2.gpu["vram_total_mb"] == 32_000
    assert length(Config.list_agents()) == 1
    assert length(Config.list_providers()) == 1
  end

  test "register/2 registers multiple slots as separate providers" do
    {:ok, %{providers: providers}} =
      Agents.register(
        @host,
        payload([
          %{"port" => 8081, "base_url" => "http://jobycorp:8081/v1"},
          %{"port" => 8082, "base_url" => "http://jobycorp:8082/v1"}
        ])
      )

    assert providers |> Enum.map(& &1.name) |> Enum.sort() == ["jobycorp:8081", "jobycorp:8082"]
  end

  test "list_agents/get_agent preload the managed providers" do
    {:ok, %{agent: agent}} = Agents.register(@host, payload())

    assert [listed] = Agents.list_agents()
    assert listed.host_id == @host
    assert [%{name: "jobycorp:8081"}] = listed.providers
    assert %{providers: [_]} = Agents.get_agent(agent.id)
  end
end
