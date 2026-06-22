defmodule AiroWeb.AgentChannelTest do
  use AiroWeb.ChannelCase, async: false

  alias Airo.{Config, Health}
  alias AiroWeb.AgentSocket

  @host "test-host"
  @model "org/repo:Q4"

  setup do
    {:ok, provider} =
      Config.create_provider(%{
        name: @host,
        adapter_type: :airo_agent,
        base_url: "http://test-host:4400",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: @model,
        capabilities: [:chat]
      })

    %{provider: provider, deployment: deployment}
  end

  # Drive a push through the channel, then sync so the (synchronous) ingest +
  # ETS write are visible to the test process before we assert.
  defp push_sync(socket, event, payload) do
    push(socket, event, payload)
    :sys.get_state(socket.channel_pid)
    :ok
  end

  defp join_host(host \\ @host) do
    {:ok, socket} = connect(AgentSocket, %{"host_id" => host})
    {:ok, _reply, socket} = subscribe_and_join(socket, "agent:#{host}", %{})
    socket
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

  test "connect enforces the token when one is configured" do
    Application.put_env(:airo, :agent_token, "secret")
    on_exit(fn -> Application.delete_env(:airo, :agent_token) end)

    assert :error = connect(AgentSocket, %{"host_id" => @host, "token" => "wrong"})
    assert {:ok, _socket} = connect(AgentSocket, %{"host_id" => @host, "token" => "secret"})
  end

  test "join rejects a topic that mismatches the socket host" do
    {:ok, socket} = connect(AgentSocket, %{"host_id" => @host})

    assert {:error, %{reason: "host_id mismatch"}} =
             subscribe_and_join(socket, "agent:someone-else", %{})
  end

  test "an :up event marks the deployment up", %{deployment: deployment} do
    socket = join_host()
    push_sync(socket, "event", %{"type" => "up", "model_id" => @model})
    assert Health.status(deployment.id) == :up
  end

  test "a :down event marks it down and persists an :agent-sourced event", %{
    deployment: deployment,
    provider: provider
  } do
    socket = join_host()
    push_sync(socket, "event", %{"type" => "up", "model_id" => @model})
    push_sync(socket, "event", %{"type" => "down", "model_id" => @model, "reason" => "cuda_oom"})

    assert Health.status(deployment.id) == :down

    events = Health.list_events() |> Enum.filter(&(&1.provider_id == provider.id))

    assert Enum.any?(
             events,
             &(&1.status == :down and &1.source == :agent and &1.reason == "cuda_oom")
           )
  end

  test "an event for an unknown model is a no-op", %{deployment: deployment} do
    socket = join_host()
    push_sync(socket, "event", %{"type" => "up", "model_id" => "nope"})
    assert Health.status(deployment.id) == :unknown
  end

  test "a snapshot reconciles absent deployments to down", %{deployment: deployment} do
    socket = join_host()
    push_sync(socket, "event", %{"type" => "up", "model_id" => @model})
    assert Health.status(deployment.id) == :up

    # Empty running set ⇒ the model is no longer loaded ⇒ down.
    push_sync(socket, "snapshot", %{"instances" => []})
    assert Health.status(deployment.id) == :down
  end

  test "disconnect marks the host's deployments down", %{deployment: deployment} do
    socket = join_host()
    push_sync(socket, "event", %{"type" => "up", "model_id" => @model})
    assert Health.status(deployment.id) == :up

    Process.unlink(socket.channel_pid)
    leave(socket)

    eventually(fn -> Health.status(deployment.id) == :down end, 50)
  end
end
