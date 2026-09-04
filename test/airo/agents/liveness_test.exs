defmodule Airo.Agents.LivenessTest do
  use Airo.DataCase, async: false

  alias Airo.Agents.{HostEvent, Ingest, Lifecycle, Liveness, SlotState}
  alias Airo.{Config, Health, Repo}
  alias Airo.Test.AgentControl

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.health_table())
    :ets.delete_all_objects(Airo.Runtime.Store.slots_table())
    :ets.delete_all_objects(Airo.Runtime.Store.hosts_table())
    # Classification, not hysteresis (S24): one `down` observation marks down.
    Airo.Test.Health.set_failure_threshold(1)
    {:ok, _} = Config.update_site_setting(%{agent_stale_after_ms: 20_000})
    Lifecycle.subscribe()
    :ok
  end

  defp host(host_id, seen_seconds_ago) do
    last_seen =
      DateTime.utc_now()
      |> DateTime.add(-seen_seconds_ago, :second)
      |> DateTime.truncate(:second)

    {:ok, agent} =
      Config.create_agent(%{
        host_id: host_id,
        control_url: "http://#{host_id}:4400",
        last_seen_at: last_seen
      })

    {:ok, provider} =
      Config.create_provider(%{
        name: "#{host_id}:8081",
        adapter_type: :openai,
        base_url: "http://#{host_id}:8081/v1",
        auth_kind: :none,
        agent_id: agent.id
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "m",
        capabilities: [:chat]
      })

    Health.mark(deployment.id, :up)
    %{agent: agent, provider: provider, deployment: deployment}
  end

  defp kinds(host_id) do
    Repo.all(from e in HostEvent, where: e.host_id == ^host_id, order_by: e.id, select: e.kind)
  end

  test "a present host silent past the threshold enters stale once" do
    %{deployment: deployment} = host("silent", 60)
    AgentControl.mark_online("silent")
    ref = :telemetry_test.attach_event_handlers(self(), [[:airo, :agent, :stale]])

    assert %{stale: ["silent"], lost: []} = Liveness.sweep()
    assert Liveness.stale?("silent")
    assert Liveness.stale_hosts() == ["silent"]
    assert kinds("silent") == [:stale]
    assert Health.status(deployment.id) == :unknown
    assert_receive {:agent_event, %{host_id: "silent", kind: :stale}}
    assert_receive {[:airo, :agent, :stale], ^ref, %{silent_ms: ms}, %{host_id: "silent"}}
    assert ms > 20_000

    # Idempotent: the second sweep neither re-records nor re-marks.
    assert %{stale: [], lost: []} = Liveness.sweep()
    assert kinds("silent") == [:stale]
  end

  test "a present host inside the threshold is left alone" do
    %{deployment: deployment} = host("fresh", 5)
    AgentControl.mark_online("fresh")

    assert %{stale: [], lost: []} = Liveness.sweep()
    refute Liveness.stale?("fresh")
    assert kinds("fresh") == []
    assert Health.status(deployment.id) == :up
  end

  test "a register clears stale with a recovered transition" do
    host("comeback", 60)
    AgentControl.mark_online("comeback")
    Liveness.sweep()
    assert Liveness.stale?("comeback")

    Ingest.register("comeback", %{
      "agent" => %{"control_url" => "http://comeback:4400"},
      "slots" => []
    })

    refute Liveness.stale?("comeback")
    assert kinds("comeback") == [:stale, :recovered]
    assert_receive {:agent_event, %{host_id: "comeback", kind: :recovered}}
  end

  test "an absent host still holding slot state is treated as a lost disconnect" do
    %{provider: provider, deployment: deployment} = host("ghost", 5)
    SlotState.put(provider.id, %{resident_model: "m", status: :up})

    assert %{stale: [], lost: ["ghost"]} = Liveness.sweep()
    assert kinds("ghost") == [:disconnected]

    assert [%{reason: "presence_lost"}] =
             Repo.all(from e in HostEvent, where: e.host_id == "ghost")

    assert SlotState.get(provider.id) == nil
    assert Health.status(deployment.id) == :down
  end

  test "an absent host with no slot state and no flag is ignored" do
    host("offline", 3600)
    assert %{stale: [], lost: []} = Liveness.sweep()
    assert kinds("offline") == []
  end

  test "a disconnect supersedes the stale flag without a recovery" do
    host("dropped", 60)
    AgentControl.mark_online("dropped")
    Liveness.sweep()
    assert Liveness.stale?("dropped")

    # Presence gone (the tracking pid is us — untrack), slot state already cleared
    # by the channel's terminate path.
    AiroWeb.Presence.untrack(self(), "agent:dropped", "dropped")
    assert %{stale: [], lost: []} = Liveness.sweep()
    refute Liveness.stale?("dropped")
    assert kinds("dropped") == [:stale]
  end

  test "the threshold is a validated site setting" do
    assert {:error, changeset} = Config.update_site_setting(%{agent_stale_after_ms: 5_000})
    assert %{agent_stale_after_ms: [_]} = errors_on(changeset)

    assert {:ok, _} = Config.update_site_setting(%{agent_stale_after_ms: 90_000})
    assert Config.agent_stale_after_ms() == 90_000
  end
end
