defmodule Airo.Agents.LifecycleTest do
  use Airo.DataCase, async: false

  alias Airo.Agents.{HostEvent, Lifecycle}
  alias Airo.Logs.LogEvent
  alias Airo.{Config, Repo}

  @host "lifecycle-host"

  setup do
    {:ok, agent} =
      Config.create_agent(%{host_id: @host, control_url: "http://lifecycle-host:4400"})

    Lifecycle.subscribe()
    %{agent: agent}
  end

  defp host_events(host \\ @host),
    do: Repo.all(from e in HostEvent, where: e.host_id == ^host, order_by: e.id)

  defp log_events, do: Repo.all(from e in LogEvent, where: e.kind == :host, order_by: e.id)

  test "writes a host_event linked to the agent, with clipped reason and string meta", %{
    agent: agent
  } do
    long = String.duplicate("x", 300)

    assert {:ok, %HostEvent{} = event} =
             Lifecycle.transition(@host, :disconnected, reason: long, meta: %{exit: "shutdown"})

    assert event.agent_id == agent.id
    assert event.kind == :disconnected
    assert String.length(event.reason) == 255
    assert event.meta == %{"exit" => "shutdown"}
    assert [%{kind: :disconnected}] = host_events()
  end

  test "a host with no agents row still gets an event" do
    assert {:ok, %HostEvent{agent_id: nil}} = Lifecycle.transition("brand-new", :connected)
    assert [%{host_id: "brand-new"}] = host_events("brand-new")
  end

  test "mirrors connect/disconnect/stale/recovered into the operational log, not identity changes" do
    Lifecycle.transition(@host, :connected, meta: %{version: "0.1.0"})
    Lifecycle.transition(@host, :version_changed, meta: %{from: "0.1.0", to: "0.2.0"})
    Lifecycle.transition(@host, :stale, reason: "no register for 47000ms")
    Lifecycle.transition(@host, :recovered)
    Lifecycle.transition(@host, :disconnected, reason: "agent_disconnected")

    assert length(host_events()) == 5

    mirrored = log_events()
    assert Enum.map(mirrored, & &1.data["kind"]) == ~w(connected stale recovered disconnected)
    assert Enum.map(mirrored, & &1.level) == [:info, :warning, :info, :warning]

    [connected | _] = mirrored
    assert connected.summary == "host connected host_id=#{@host}"
    assert connected.data["host_id"] == @host
    assert connected.data["version"] == "0.1.0"
  end

  test "broadcasts on the fleet topic" do
    Lifecycle.transition(@host, :connected)
    assert_receive {:agent_event, %{host_id: @host, kind: :connected}}

    Lifecycle.transition(@host, :stale)
    assert_receive {:agent_event, %{host_id: @host, kind: :stale}}
  end

  test "executes the catalogued telemetry event with host metadata and measurements" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:airo, :agent, :join],
        [:airo, :agent, :leave],
        [:airo, :agent, :stale],
        [:airo, :agent, :changed]
      ])

    Lifecycle.transition(@host, :connected, meta: %{version: "0.1.0"})

    assert_receive {[:airo, :agent, :join], ^ref, %{count: 1},
                    %{host_id: @host, version: "0.1.0"}}

    Lifecycle.transition(@host, :stale, measurements: %{silent_ms: 47_000})

    assert_receive {[:airo, :agent, :stale], ^ref, %{count: 1, silent_ms: 47_000},
                    %{host_id: @host}}

    Lifecycle.transition(@host, :control_url_changed, meta: %{field: :control_url})

    assert_receive {[:airo, :agent, :changed], ^ref, _,
                    %{host_id: @host, kind: :control_url_changed, field: :control_url}}

    Lifecycle.transition(@host, :disconnected)
    assert_receive {[:airo, :agent, :leave], ^ref, _, %{host_id: @host}}
  end

  test "recent/2 lists a host's events newest first, capped" do
    for kind <- [:connected, :stale, :recovered, :disconnected],
        do: Lifecycle.transition(@host, kind)

    Lifecycle.transition("other-host", :connected)

    assert [%{kind: :disconnected}, %{kind: :recovered}, %{kind: :stale}] =
             Lifecycle.recent(@host, 3)
  end

  test "the prune worker removes only rows past the retention window" do
    Lifecycle.transition(@host, :connected)
    {:ok, old} = Lifecycle.transition(@host, :disconnected)

    old_time = NaiveDateTime.utc_now() |> NaiveDateTime.add(-40 * 86_400, :second)
    Repo.update_all(from(e in HostEvent, where: e.id == ^old.id), set: [inserted_at: old_time])

    assert {:ok, 1} = Airo.Agents.PruneWorker.perform(%Oban.Job{})
    assert [%{kind: :connected}] = host_events()
  end
end
