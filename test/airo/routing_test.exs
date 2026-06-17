defmodule Airo.RoutingTest do
  use Airo.DataCase, async: true

  alias Airo.{Config, Health, Routing}

  defp provider(name, opts \\ []) do
    {:ok, p} =
      Config.create_provider(%{
        name: name,
        adapter_type: :vllm,
        base_url: "http://#{name}/v1",
        auth_kind: :none,
        enabled: Keyword.get(opts, :enabled, true)
      })

    p
  end

  defp deployment(provider, model, opts \\ []) do
    {:ok, d} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: model,
        capabilities: Keyword.get(opts, :capabilities, [:chat]),
        class: opts[:class],
        tool_use: Keyword.get(opts, :tool_use, false),
        enabled: Keyword.get(opts, :enabled, true)
      })

    d
  end

  defp alias_with(name, candidates, opts \\ []) do
    {:ok, _} =
      Config.create_alias(%{
        name: name,
        capability: :chat,
        strategy: Keyword.get(opts, :strategy, :priority),
        fallback: Keyword.get(opts, :fallback, []),
        candidates: candidates
      })

    Config.get_alias_by_name(name)
  end

  defp cand(deployment, opts),
    do: %{
      deployment_id: deployment.id,
      weight: Keyword.get(opts, :weight, 100),
      priority: Keyword.get(opts, :priority, 0)
    }

  defp ids({:ok, candidates}), do: Enum.map(candidates, & &1.deployment.id)

  describe "strategy: priority" do
    test "orders by ascending priority" do
      da = deployment(provider("pa"), "ma")
      db = deployment(provider("pb"), "mb")
      al = alias_with("al", [cand(da, priority: 1), cand(db, priority: 0)])

      assert ids(Routing.candidates(al, %{})) == [db.id, da.id]
    end

    test "drops disabled deployments and providers" do
      da = deployment(provider("pa"), "ma")
      db = deployment(provider("pb", enabled: false), "mb")
      al = alias_with("al", [cand(da, priority: 0), cand(db, priority: 1)])

      assert ids(Routing.candidates(al, %{})) == [da.id]
    end
  end

  describe "capability filter" do
    test "keeps only deployments whose capabilities include the requested resource" do
      chat = deployment(provider("pc"), "mc", capabilities: [:chat])
      vis = deployment(provider("pv"), "mv", capabilities: [:vision])
      both = deployment(provider("pbo"), "mbo", capabilities: [:chat, :vision])

      al =
        alias_with("al", [
          cand(chat, priority: 0),
          cand(vis, priority: 1),
          cand(both, priority: 2)
        ])

      assert ids(Routing.candidates(al, %{}, :vision)) == [vis.id, both.id]
      assert ids(Routing.candidates(al, %{}, :chat)) == [chat.id, both.id]
    end

    test "a nil capability skips the filter" do
      chat = deployment(provider("pc"), "mc", capabilities: [:chat])
      vis = deployment(provider("pv"), "mv", capabilities: [:vision])
      al = alias_with("al", [cand(chat, priority: 0), cand(vis, priority: 1)])

      assert ids(Routing.candidates(al, %{}, nil)) == [chat.id, vis.id]
    end
  end

  describe "health preference" do
    test "prefers :up over :down regardless of priority, but still keeps :down" do
      da = deployment(provider("pa"), "ma")
      db = deployment(provider("pb"), "mb")
      # db has the better (lower) priority, but is down.
      al = alias_with("al", [cand(da, priority: 1), cand(db, priority: 0)])

      Health.mark(da.id, :up)
      Health.mark(db.id, :down)

      assert ids(Routing.candidates(al, %{})) == [da.id, db.id]
    end
  end

  describe "strict pin (route.binding)" do
    test "serves exactly the bound deployment" do
      da = deployment(provider("pa"), "ma")
      db = deployment(provider("pb"), "mb")
      al = alias_with("al", [cand(da, priority: 0), cand(db, priority: 1)])

      assert ids(Routing.candidates(al, %{"binding" => "vllm:mb"})) == [db.id]
      assert ids(Routing.candidates(al, %{"binding" => "pb:mb"})) == [db.id]
    end

    test "unavailable binding never substitutes" do
      da = deployment(provider("pa"), "ma")
      al = alias_with("al", [cand(da, priority: 0)])

      assert Routing.candidates(al, %{"binding" => "vllm:ghost"}) ==
               {:error, :selected_binding_unavailable}
    end
  end

  describe "route filters" do
    test "tools filter keeps only tool-capable deployments" do
      dt = deployment(provider("pa"), "mt", tool_use: true)
      dn = deployment(provider("pb"), "mn", tool_use: false)
      al = alias_with("al", [cand(dt, priority: 0), cand(dn, priority: 1)])

      assert ids(Routing.candidates(al, %{"tools" => true})) == [dt.id]
    end

    test "class filter narrows to the requested class" do
      dd = deployment(provider("pa"), "md", class: :deep)
      ds = deployment(provider("pb"), "ms", class: :standard)
      al = alias_with("al", [cand(dd, priority: 0), cand(ds, priority: 1)])

      assert ids(Routing.candidates(al, %{"class" => "deep"})) == [dd.id]
    end
  end

  describe "fallback chain" do
    test "appends fallback-alias candidates, de-duplicated, after the primary" do
      da = deployment(provider("pa"), "ma")
      dc = deployment(provider("pc"), "mc")
      _fallback = alias_with("fb", [cand(dc, priority: 0)])
      al = alias_with("al", [cand(da, priority: 0)], fallback: ["fb"])

      assert ids(Routing.candidates(al, %{})) == [da.id, dc.id]
    end

    test "route.fallback overrides the alias fallback" do
      da = deployment(provider("pa"), "ma")
      dc = deployment(provider("pc"), "mc")
      _fb = alias_with("fb", [cand(dc, priority: 0)])
      al = alias_with("al", [cand(da, priority: 0)])

      assert ids(Routing.candidates(al, %{"fallback" => ["fb"]})) == [da.id, dc.id]
    end
  end

  describe "strategy: round_robin" do
    test "rotates the candidate order across calls" do
      da = deployment(provider("pa"), "ma")
      db = deployment(provider("pb"), "mb")

      al =
        alias_with("rr", [cand(da, priority: 0), cand(db, priority: 1)], strategy: :round_robin)

      heads = for _ <- 1..4, do: hd(elem(Routing.candidates(al, %{}), 1)).deployment.id
      assert heads == [da.id, db.id, da.id, db.id]
    end
  end

  describe "strategy: weighted" do
    test "returns all candidates (order is randomized by weight)" do
      da = deployment(provider("pa"), "ma")
      db = deployment(provider("pb"), "mb")
      al = alias_with("w", [cand(da, weight: 90), cand(db, weight: 10)], strategy: :weighted)

      assert {:ok, candidates} = Routing.candidates(al, %{})
      assert MapSet.new(Enum.map(candidates, & &1.deployment.id)) == MapSet.new([da.id, db.id])
    end
  end
end
