defmodule AiroWeb.AgentChannelTest do
  use AiroWeb.ChannelCase, async: false

  # These assert health *classification*, not how many failures it takes (S24).
  setup do
    Airo.Test.Health.set_failure_threshold(1)
    :ok
  end

  alias Airo.{Config, Health}
  alias AiroWeb.AgentSocket

  @host "test-host"
  @port 8081
  @engine "http://test-host:8081/v1"
  @model "org/repo:Q4"

  defp register_payload(opts \\ []) do
    %{
      "agent" => %{"control_url" => "http://test-host:4400", "version" => "0.1.0"},
      "slots" => [
        %{
          "port" => @port,
          "base_url" => @engine,
          "resident_model" => opts[:resident],
          "status" => opts[:status] || "empty"
        }
      ]
    }
  end

  defp join_host(host \\ @host) do
    {:ok, socket} = connect(AgentSocket, %{"host_id" => host})
    {:ok, _reply, socket} = subscribe_and_join(socket, "agent:#{host}", %{})
    socket
  end

  defp push_sync(socket, event, payload) do
    push(socket, event, payload)
    :sys.get_state(socket.channel_pid)
    :ok
  end

  defp slot_provider, do: Config.get_provider_by_name("#{@host}:#{@port}")

  defp deployment(model) do
    {:ok, dep} =
      Config.create_deployment(%{
        provider_id: slot_provider().id,
        model_name: model,
        capabilities: [:chat]
      })

    dep
  end

  defp eventually(_fun, 0), do: flunk("condition never became true")

  defp eventually(fun, tries) do
    unless fun.() do
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end

  test "connect requires a host_id" do
    assert :error = connect(AgentSocket, %{})
  end

  test "join rejects a topic that mismatches the socket host" do
    {:ok, socket} = connect(AgentSocket, %{"host_id" => @host})

    assert {:error, %{reason: "host_id mismatch"}} =
             subscribe_and_join(socket, "agent:someone-else", %{})
  end

  test "register upserts the agent and a managed slot provider" do
    socket = join_host()
    push_sync(socket, "register", register_payload())

    agent = Config.get_agent_by_host_id(@host)
    assert agent.control_url == "http://test-host:4400"

    provider = slot_provider()
    assert provider.agent_id == agent.id
    assert provider.base_url == @engine
    # A managed slot speaks plain OpenAI — base_url is the real engine endpoint.
    assert provider.adapter_type == :openai
  end

  test "a slot's resident model marks that deployment up" do
    socket = join_host()
    push_sync(socket, "register", register_payload())
    dep = deployment(@model)

    push_sync(socket, "slot", %{"port" => @port, "resident_model" => @model, "status" => "up"})

    assert Health.status(dep.id) == :up
  end

  test "non-resident models under the same slot are down" do
    socket = join_host()
    push_sync(socket, "register", register_payload())
    a = deployment("model-A")
    b = deployment("model-B")

    push_sync(socket, "slot", %{"port" => @port, "resident_model" => "model-A", "status" => "up"})

    assert Health.status(a.id) == :up
    assert Health.status(b.id) == :down
  end

  test "a crashed slot marks the resident deployment down with the reason" do
    socket = join_host()
    push_sync(socket, "register", register_payload())
    dep = deployment(@model)
    push_sync(socket, "slot", %{"port" => @port, "resident_model" => @model, "status" => "up"})
    assert Health.status(dep.id) == :up

    push_sync(socket, "slot", %{
      "port" => @port,
      "resident_model" => @model,
      "status" => "down",
      "reason" => "cuda_oom"
    })

    assert Health.status(dep.id) == :down
  end

  test "disconnect marks the agent's deployments down" do
    socket = join_host()
    push_sync(socket, "register", register_payload())
    dep = deployment(@model)
    push_sync(socket, "slot", %{"port" => @port, "resident_model" => @model, "status" => "up"})
    assert Health.status(dep.id) == :up

    Process.unlink(socket.channel_pid)
    leave(socket)

    eventually(fn -> Health.status(dep.id) == :down end, 50)
  end
end
