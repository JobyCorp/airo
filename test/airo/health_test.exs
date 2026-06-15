defmodule Airo.HealthTest do
  # The health table is a global ETS table; use unique deployment ids per test
  # so concurrent tests can't collide.
  use ExUnit.Case, async: true

  alias Airo.Health
  alias Airo.Runtime.Store

  defp id, do: System.unique_integer([:positive])

  test "unknown for a never-probed deployment" do
    assert Health.status(id()) == :unknown
    refute Health.healthy?(id())
  end

  test "mark/status round-trip and latency snapshot" do
    d = id()
    assert :ok = Health.mark(d, :up, 7)
    assert Health.status(d) == :up
    assert Health.healthy?(d)
    assert Health.get(d).latency_ms == 7

    Health.mark(d, :down)
    assert Health.status(d) == :down
    refute Health.healthy?(d)
  end

  test "a stale snapshot decays to :unknown" do
    d = id()
    old = System.monotonic_time(:millisecond) - (Health.staleness_ms() + 1_000)
    :ets.insert(Store.health_table(), {d, %{status: :up, latency_ms: nil, checked_at: old}})

    assert Health.status(d) == :unknown
  end
end
