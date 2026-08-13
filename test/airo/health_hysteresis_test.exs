defmodule Airo.HealthHysteresisTest do
  @moduledoc """
  A single failure is not an outage (S24).

  Before this, one slow probe or one timed-out request marked a working model
  down and something reversed it seconds later — in one production day,
  `dispatch` alone wrote 21 downs against 1 up, each undone in about four
  seconds. These pin the behaviour that stopped it.
  """
  use Airo.DataCase, async: false

  import Airo.Test.Health

  alias Airo.Config
  alias Airo.Health

  defp deployment_and_provider(name) do
    {:ok, provider} =
      Config.create_provider(%{
        name: name,
        adapter_type: :openai,
        base_url: "http://#{name}:8081/v1",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "#{name}-model",
        capabilities: [:chat]
      })

    {deployment, provider}
  end

  defp fail(deployment, provider, opts \\ []) do
    Health.mark_deployment(deployment, provider, :down, Keyword.put_new(opts, :reason, "boom"))
  end

  describe "the threshold" do
    test "a deployment survives fewer failures than the threshold" do
      set_failure_threshold(3)
      {d, p} = deployment_and_provider("survives")
      Health.mark_deployment(d, p, :up)

      fail(d, p)
      assert Health.status(d.id) == :up, "one failure must not be an outage"

      fail(d, p)
      assert Health.status(d.id) == :up, "two failures must not be an outage either"
    end

    test "the Nth consecutive failure takes it down" do
      set_failure_threshold(3)
      {d, p} = deployment_and_provider("takes-down")
      Health.mark_deployment(d, p, :up)

      fail(d, p)
      fail(d, p)
      fail(d, p)

      assert Health.status(d.id) == :down
    end

    test "one success resets the counter" do
      set_failure_threshold(3)
      {d, p} = deployment_and_provider("resets")
      Health.mark_deployment(d, p, :up)

      fail(d, p)
      fail(d, p)
      Health.mark_deployment(d, p, :up)

      # Without the reset these next two would be the 3rd and 4th failures.
      fail(d, p)
      fail(d, p)
      assert Health.status(d.id) == :up
    end

    test "recovery is immediate — no threshold on the way up" do
      set_failure_threshold(2)
      {d, p} = deployment_and_provider("recovers")
      fail(d, p)
      fail(d, p)
      assert Health.status(d.id) == :down

      Health.mark_deployment(d, p, :up)
      assert Health.status(d.id) == :up, "a real recovery must never be delayed"
    end

    test "a threshold of 1 is the old immediate behaviour" do
      set_failure_threshold(1)
      {d, p} = deployment_and_provider("immediate")
      Health.mark_deployment(d, p, :up)

      fail(d, p)
      assert Health.status(d.id) == :down
    end

    test "suppressed failures write no event, so the log stops carrying fiction" do
      set_failure_threshold(3)
      {d, p} = deployment_and_provider("no-event")
      Health.mark_deployment(d, p, :up)

      before = Repo.aggregate(Airo.Health.HealthEvent, :count)
      fail(d, p)
      fail(d, p)

      assert Repo.aggregate(Airo.Health.HealthEvent, :count) == before,
             "a failure below the threshold is not a transition and must not be recorded"
    end
  end

  describe "lifecycle transitions" do
    test "a loading slot is history but not an operational log line" do
      set_failure_threshold(1)
      {d, p} = deployment_and_provider("loading-slot")
      Health.mark_deployment(d, p, :up)

      events_before = Repo.aggregate(Airo.Health.HealthEvent, :count)
      logs_before = Repo.aggregate(Airo.Logs.LogEvent, :count)

      Health.mark_deployment(d, p, :unknown, source: :agent, reason: "loading")

      assert Repo.aggregate(Airo.Health.HealthEvent, :count) == events_before + 1,
             "health_events keeps the full sequence"

      assert Repo.aggregate(Airo.Logs.LogEvent, :count) == logs_before,
             "a reload is not an incident and must not reach /admin/logs"
    end

    test "a real failure still reaches the log" do
      set_failure_threshold(1)
      {d, p} = deployment_and_provider("real-failure")
      Health.mark_deployment(d, p, :up)

      logs_before = Repo.aggregate(Airo.Logs.LogEvent, :count)
      fail(d, p, reason: "tp_cluster_incomplete")

      assert Repo.aggregate(Airo.Logs.LogEvent, :count) == logs_before + 1,
             "suppressing lifecycle noise must not suppress the signal underneath it"
    end
  end
end
