defmodule Airo.Routing.AffinityTest do
  use Airo.DataCase, async: true

  alias Airo.{Config, Health, Routing}
  alias Airo.Gateway.InFlight
  alias Airo.Routing.Affinity
  alias Airo.Runtime.Store

  defp deployment(opts \\ []) do
    name = "p-#{System.unique_integer([:positive])}"

    {:ok, p} =
      Config.create_provider(%{
        name: name,
        adapter_type: :vllm,
        base_url: "http://#{name}/v1",
        auth_kind: :none
      })

    {:ok, d} =
      Config.create_deployment(%{
        provider_id: p.id,
        model_name: "m",
        capabilities: [:chat],
        enabled: Keyword.get(opts, :enabled, true)
      })

    d
  end

  defp alias_with(deployments, opts \\ []) do
    name = "a-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Config.create_alias(%{
        name: name,
        capability: :chat,
        strategy: Keyword.get(opts, :strategy, :affinity),
        fallback: Keyword.get(opts, :fallback, []),
        candidates:
          deployments
          |> Enum.with_index()
          |> Enum.map(fn {d, i} -> %{deployment_id: d.id, weight: 100, priority: i} end)
      })

    Config.get_alias_by_name(name)
  end

  # Head deployment id + outcome for one routing call.
  defp route(alias_, route) do
    {:ok, [head | _], outcome} = Routing.route(alias_, route, :chat)
    {head.deployment.id, outcome}
  end

  # Hold `n` in-flight entries on a deployment from processes that live until
  # the test exits.
  defp busy(deployment, n) do
    parent = self()

    for _ <- 1..n do
      spawn_link(fn ->
        InFlight.track(deployment.id)
        send(parent, :tracked)
        Process.sleep(:infinity)
      end)

      assert_receive :tracked
    end
  end

  test "20 requests with one key go to one card" do
    al = alias_with([deployment(), deployment(), deployment()])

    [{first, :assigned} | rest] = for _ <- 1..20, do: route(al, %{"affinity" => "s1"})

    assert length(rest) == 19
    assert Enum.all?(rest, &(&1 == {first, :hit}))
  end

  test "a new key goes to the card with the fewest in-flight requests" do
    [da, db] = [deployment(), deployment()]
    al = alias_with([da, db])
    busy(da, 2)

    for i <- 1..4, do: assert(route(al, %{"affinity" => "k#{i}"}) == {db.id, :assigned})
  end

  test "two new keys go to different cards when one card is busier" do
    [da, db] = [deployment(), deployment()]
    al = alias_with([da, db])

    {first, :assigned} = route(al, %{"affinity" => "k1"})
    # k1's round is in flight on its card, so that card is now the busier one.
    busy(if(first == da.id, do: da, else: db), 1)
    {second, :assigned} = route(al, %{"affinity" => "k2"})

    assert first != second
  end

  test "at idle, new keys spread across cards by live key count" do
    [da, db] = [deployment(), deployment()]
    al = alias_with([da, db])

    heads = for i <- 1..4, do: elem(route(al, %{"affinity" => "k#{i}"}), 0)

    assert Enum.frequencies(heads) == %{da.id => 2, db.id => 2}
  end

  test "a card marked down causes a reassignment, and the key stays on the new card" do
    [da, db] = [deployment(), deployment()]
    al = alias_with([da, db])

    {first, :assigned} = route(al, %{"affinity" => "s"})
    other = if first == da.id, do: db.id, else: da.id
    Health.mark(first, :down)

    assert route(al, %{"affinity" => "s"}) == {other, :reassigned}
    assert route(al, %{"affinity" => "s"}) == {other, :hit}
    assert Affinity.assignment(al.id, "s") == other
  end

  test "a disabled card causes a reassignment" do
    [da, db] = [deployment(), deployment()]
    al = alias_with([da, db])

    {first, :assigned} = route(al, %{"affinity" => "s"})
    {:ok, _} = Config.update_deployment(Repo.get!(Config.Deployment, first), %{enabled: false})
    other = if first == da.id, do: db.id, else: da.id

    assert route(al, %{"affinity" => "s"}) == {other, :reassigned}
  end

  test "an expired key is assigned again" do
    al = alias_with([deployment(), deployment()])
    {_first, :assigned} = route(al, %{"affinity" => "s"})

    stale = System.monotonic_time(:millisecond) - Affinity.idle_ms() - 1
    :ets.update_element(Store.routing_table(), {:affinity, al.id, "s"}, {3, stale})

    assert {_, :assigned} = route(al, %{"affinity" => "s"})
  end

  test "a new key sweeps idle keys out of the table" do
    al = alias_with([deployment(), deployment()])
    {_first, :assigned} = route(al, %{"affinity" => "old"})
    stale = System.monotonic_time(:millisecond) - Affinity.idle_ms() - 1
    :ets.update_element(Store.routing_table(), {:affinity, al.id, "old"}, {3, stale})

    # A new key sweeps idle ones out of the table.
    {_head, :assigned} = route(al, %{"affinity" => "new"})

    assert Affinity.assignment(al.id, "old") == nil
    assert Affinity.assignment(al.id, "new") != nil
  end

  test "no key behaves exactly like round-robin" do
    [da, db] = [deployment(), deployment()]
    affinity = alias_with([da, db])
    rr = alias_with([da, db], strategy: :round_robin)

    heads = fn al -> for _ <- 1..4, do: route(al, %{}) end

    assert heads.(affinity) == [{da.id, :none}, {db.id, :none}, {da.id, :none}, {db.id, :none}]
    assert Enum.map(heads.(rr), &elem(&1, 0)) == [da.id, db.id, da.id, db.id]
  end

  test "round-robin ignores a key and reports :none" do
    [da, db] = [deployment(), deployment()]
    al = alias_with([da, db], strategy: :round_robin)

    heads = for _ <- 1..4, do: route(al, %{"affinity" => "s"})

    assert heads == [{da.id, :none}, {db.id, :none}, {da.id, :none}, {db.id, :none}]
    assert Affinity.assignment(al.id, "s") == nil
  end

  test "route.binding wins over affinity and leaves the key unassigned" do
    [da, db] = [deployment(), deployment()]
    al = alias_with([da, db])
    binding = "vllm:m"

    assert {:ok, [_], :none} = Routing.route(al, %{"binding" => binding, "affinity" => "s"})
    assert Affinity.assignment(al.id, "s") == nil
  end

  test "failover order keeps every candidate after the assigned card" do
    [da, db, dc] = [deployment(), deployment(), deployment()]
    al = alias_with([da, db, dc])

    {:ok, list, :assigned} = Routing.route(al, %{"affinity" => "s"}, :chat)

    assert Enum.sort(Enum.map(list, & &1.deployment.id)) == Enum.sort([da.id, db.id, dc.id])
  end

  test "a fallback alias with the affinity strategy does not take the key" do
    [da, db] = [deployment(), deployment()]
    fb = alias_with([db])
    al = alias_with([da], fallback: [fb.name])

    {:ok, list, :assigned} = Routing.route(al, %{"affinity" => "s"}, :chat)

    assert Enum.map(list, & &1.deployment.id) == [da.id, db.id]
    assert Affinity.assignment(fb.id, "s") == nil
  end

  test "valid_key?/1 accepts nil and strings up to 128 bytes" do
    assert Affinity.valid_key?(nil)
    assert Affinity.valid_key?(String.duplicate("a", 128))
    refute Affinity.valid_key?(String.duplicate("a", 129))
    refute Affinity.valid_key?(42)
  end
end
