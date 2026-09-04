defmodule AiroWeb.AgentChannelTest do
  use AiroWeb.ChannelCase, async: false

  # These assert health *classification*, not how many failures it takes (S24).
  setup do
    Airo.Test.Health.set_failure_threshold(1)
    :ok
  end

  alias Airo.{Config, Health, Repo}
  alias Airo.Agents.HostEvent
  alias AiroWeb.AgentSocket

  import Ecto.Query, only: [from: 2]

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

  defp host_events(host \\ @host),
    do: Repo.all(from e in HostEvent, where: e.host_id == ^host, order_by: e.id)

  test "join records a connected event on the fleet topic; leave records disconnected" do
    Phoenix.PubSub.subscribe(Airo.PubSub, Airo.Agents.Lifecycle.topic())
    socket = join_host()

    assert_receive {:agent_event, %{host_id: @host, kind: :connected}}
    assert [%{kind: :connected, agent_id: nil}] = host_events()

    Process.unlink(socket.channel_pid)
    leave(socket)

    assert_receive {:agent_event, %{host_id: @host, kind: :disconnected}}
    eventually(fn -> match?([_, %{kind: :disconnected}], host_events()) end, 50)
    [_, disconnected] = host_events()
    assert disconnected.reason == "agent_disconnected"
  end

  test "a heartbeat register writes no host event; a changed version writes one" do
    socket = join_host()
    push_sync(socket, "register", register_payload())
    push_sync(socket, "register", register_payload())
    assert [%{kind: :connected}] = host_events()

    changed = put_in(register_payload(), ["agent", "version"], "0.2.0")
    push_sync(socket, "register", changed)

    assert [%{kind: :connected}, %{kind: :version_changed} = event] = host_events()
    assert event.meta == %{"field" => "version", "from" => "0.1.0", "to" => "0.2.0"}
    assert event.agent_id == Config.get_agent_by_host_id(@host).id
  end

  test "register and slot pushes emit telemetry" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:airo, :agent, :register],
        [:airo, :agent, :slot]
      ])

    socket = join_host()
    push_sync(socket, "register", register_payload())
    assert_receive {[:airo, :agent, :register], ^ref, %{count: 1, slots: 1}, %{host_id: @host}}

    push_sync(socket, "slot", %{"port" => @port, "resident_model" => @model, "status" => "up"})

    assert_receive {[:airo, :agent, :slot], ^ref, %{count: 1},
                    %{host_id: @host, port: @port, status: "up"}}
  end

  describe "roles (S26)" do
    test "connect accepts controller and observer, defaults to controller, refuses anything else" do
      assert {:ok, socket} = connect(AgentSocket, %{"host_id" => @host})
      assert socket.assigns.role == :controller

      assert {:ok, socket} = connect(AgentSocket, %{"host_id" => @host, "role" => "observer"})
      assert socket.assigns.role == :observer

      assert :error = connect(AgentSocket, %{"host_id" => @host, "role" => "admin"})
    end

    test "the connected event and Presence carry the connection's role" do
      Phoenix.PubSub.subscribe(Airo.PubSub, Airo.Agents.Lifecycle.topic())
      {:ok, socket} = connect(AgentSocket, %{"host_id" => @host, "role" => "observer"})
      {:ok, _reply, _socket} = subscribe_and_join(socket, "agent:#{@host}", %{})

      assert_receive {:agent_event, %{host_id: @host, kind: :connected}}
      assert [%{kind: :connected, meta: %{"role" => "observer"}}] = host_events()
      assert %{@host => %{metas: [%{role: :observer}]}} = AiroWeb.Presence.list("agent:#{@host}")
    end

    test "register persists the reported role; a change is a role_changed event" do
      socket = join_host()
      push_sync(socket, "register", put_in(register_payload(), ["agent", "role"], "observer"))
      assert Config.get_agent_by_host_id(@host).role == :observer

      # A pre-S26 agent sends no role and leaves it alone.
      push_sync(socket, "register", register_payload())
      assert Config.get_agent_by_host_id(@host).role == :observer

      push_sync(socket, "register", put_in(register_payload(), ["agent", "role"], "controller"))
      assert Config.get_agent_by_host_id(@host).role == :controller

      assert [%{kind: :connected}, %{kind: :role_changed} = event] = host_events()
      assert event.meta == %{"field" => "role", "from" => "observer", "to" => "controller"}
    end
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
