defmodule Airo.Gateway.InFlightTest do
  # The Registry is global to the node, so ids here are unique per test and the
  # module is async: two tests never share a deployment id.
  use ExUnit.Case, async: true

  alias Airo.Gateway.InFlight

  defp id, do: System.unique_integer([:positive]) + 1_000_000

  test "counts the calling process while tracked and releases on release/1" do
    id = id()
    assert InFlight.count(id) == 0

    assert :ok = InFlight.track(id, %{capability: :chat})
    assert InFlight.count(id) == 1

    assert :ok = InFlight.release(id)
    assert InFlight.count(id) == 0
  end

  test "an entry dies with the process that registered it, with no release call" do
    id = id()
    parent = self()

    pid =
      spawn(fn ->
        InFlight.track(id, %{capability: :stream})
        send(parent, :tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :tracked
    assert InFlight.count(id) == 1

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Registry cleanup runs after the DOWN reaches it; give it a scheduler turn.
    assert eventually(fn -> InFlight.count(id) == 0 end)
  end

  test "two processes on one deployment count two" do
    id = id()
    parent = self()

    for _ <- 1..2 do
      spawn(fn ->
        InFlight.track(id)
        send(parent, :tracked)
        Process.sleep(:infinity)
      end)
    end

    assert_receive :tracked
    assert_receive :tracked
    assert InFlight.count(id) == 2
  end

  test "snapshot/0 lists only deployments with something in flight" do
    busy = id()
    idle = id()
    InFlight.track(busy)

    snapshot = InFlight.snapshot()
    assert snapshot[busy] == 1
    refute Map.has_key?(snapshot, idle)

    InFlight.release(busy)
  end

  test "a nil deployment id is a no-op on every call" do
    assert :ok = InFlight.track(nil)
    assert :ok = InFlight.release(nil)
    assert InFlight.count(nil) == 0
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
