defmodule AiroWeb.AgentLiveOnlineTest do
  @moduledoc """
  `/admin/agents/:id` with the host **online** (S23).

  Everything here renders only when `Presence` says the host is up, which is
  why none of it had ever been rendered by the suite — and why a broken button
  variant reached production with 545 tests green.

  `async: false` on purpose: the inventory fetch happens inside the LiveView
  process at mount, so the `Req.Test` stub has to be shared rather than owned
  by the test. See `Airo.Test.AgentControl`.
  """
  use AiroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Airo.Test.AgentControl

  alias Airo.Agents.SlotState
  alias Airo.Config

  # A distinct host per test: the Presence tracker is shared, so reusing an id
  # turns a leak into a failure in some unrelated test.
  defp online_agent(host_id) do
    {:ok, agent} =
      Config.create_agent(%{
        host_id: host_id,
        control_url: "http://#{host_id}:4400",
        version: "0.1.0",
        gpu: %{
          "available" => true,
          "vram_used_mb" => 12_000,
          "vram_total_mb" => 32_000,
          "util_pct" => 10
        }
      })

    {:ok, provider} =
      Config.create_provider(%{
        name: "#{host_id}:8081",
        adapter_type: :openai,
        base_url: "http://#{host_id}:8081/v1",
        auth_kind: :none,
        agent_id: agent.id
      })

    mark_online(host_id)
    {agent, provider}
  end

  describe "loadable models" do
    test "lists the host's inventory with a Load action", %{conn: conn} do
      {agent, _} = online_agent("inv-host")
      stub_inventory([model("qwen3-30b"), model("bge-m3")])

      {:ok, _view, html} = live(conn, ~p"/admin/agents/#{agent.id}")

      assert html =~ "qwen3-30b"
      assert html =~ "bge-m3"
      assert html =~ "Load"
    end

    test "a resident model renders Configure rather than Load", %{conn: conn} do
      # THE REGRESSION TEST. This is the exact state that returned 500 in
      # production: the action button's variant is computed per row —
      # `variant={if model.resident?, do: ..., else: "primary"}` — and the
      # resident branch passed a variant JobyKit's button doesn't define, so
      # `Map.fetch!` raised. Reverting f265bd2 must fail this test.
      {agent, provider} = online_agent("resident-host")

      SlotState.put(provider.id, %{resident_model: "qwen3-30b", status: :up, ctx: 8192})
      stub_inventory([model("qwen3-30b")])

      {:ok, _view, html} = live(conn, ~p"/admin/agents/#{agent.id}")

      assert html =~ "qwen3-30b"
      assert html =~ "Configure"
      assert html =~ "resident"
    end

    test "says so when the host reports no models", %{conn: conn} do
      {agent, _} = online_agent("empty-host")
      stub_inventory([])

      {:ok, _view, html} = live(conn, ~p"/admin/agents/#{agent.id}")

      assert html =~ "No local models"
    end

    test "surfaces the reason when the control API is unreachable", %{conn: conn} do
      {agent, _} = online_agent("broken-host")

      stub_control(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      {:ok, _view, html} = live(conn, ~p"/admin/agents/#{agent.id}")

      # An operator needs the reason, not an empty table.
      assert html =~ "Inventory unavailable"
    end

    test "refresh re-scans the host and picks up a new model", %{conn: conn} do
      {agent, _} = online_agent("refresh-host")
      stub_inventory([model("before-refresh")])

      {:ok, view, html} = live(conn, ~p"/admin/agents/#{agent.id}")
      assert html =~ "before-refresh"

      stub_control(fn conn ->
        Req.Test.json(conn, %{"models" => [model("after-refresh")]})
      end)

      html = view |> element(~s{[phx-click="refresh_inventory"]}) |> render_click()

      assert html =~ "after-refresh"
    end
  end

  describe "controls that need a live host" do
    test "slot actions are enabled when the host is online", %{conn: conn} do
      {agent, provider} = online_agent("slot-host")
      SlotState.put(provider.id, %{resident_model: "qwen3-30b", status: :up})
      stub_inventory([])

      {:ok, view, _html} = live(conn, ~p"/admin/agents/#{agent.id}")

      refute render(view) =~ "Controls are disabled while the host is offline."
      assert has_element?(view, ~s{[phx-click="unload"]})
      refute render(element(view, ~s{[phx-click="resync"]})) =~ "disabled"
    end

    test "unload asks the agent and reports back", %{conn: conn} do
      {agent, provider} = online_agent("unload-host")
      SlotState.put(provider.id, %{resident_model: "qwen3-30b", status: :up})

      stub_control(fn conn ->
        case conn.request_path do
          "/inventory" -> Req.Test.json(conn, %{"models" => []})
          _ -> Req.Test.json(conn, %{"port" => 8081, "status" => "unloading"})
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/admin/agents/#{agent.id}")

      html = view |> element(~s{[phx-click="unload"]}) |> render_click()

      assert html =~ "Unloading"
    end

    test "resync broadcasts to the agent without crashing the view", %{conn: conn} do
      {agent, _} = online_agent("resync-host")
      stub_inventory([])

      {:ok, view, _html} = live(conn, ~p"/admin/agents/#{agent.id}")

      html = view |> element(~s{[phx-click="resync"]}) |> render_click()

      assert html =~ "re-report its slots"
      assert Process.alive?(view.pid)
    end
  end

  describe "config modal" do
    test "opens for a model and offers to load it", %{conn: conn} do
      {agent, _} = online_agent("modal-host")
      stub_inventory([model("qwen3-30b")])

      {:ok, view, _html} = live(conn, ~p"/admin/agents/#{agent.id}")

      html = render_click(view, "open_config", %{"model" => "qwen3-30b"})

      assert html =~ "qwen3-30b"
      assert has_element?(view, "#config-form")
    end

    test "blocks a model whose weights alone exceed the VRAM budget", %{conn: conn} do
      # S21's hard block, reached on open. The documented failure is a
      # KV-cudaMalloc segfault on the host, so this guard is why the modal
      # exists in this shape — and it had never been exercised through the page.
      #
      # 40 GiB of weights against a 32 GB card: `Capacity.validate/1` returns
      # `fits?: false` from the weights floor alone, without needing a
      # calibrated per-context cost.
      {agent, _} = online_agent("vram-host")

      stub_inventory([
        model("too-big", %{"size_bytes" => 40 * 1024 * 1024 * 1024, "ctx_max" => 32_768})
      ])

      {:ok, view, _html} = live(conn, ~p"/admin/agents/#{agent.id}")

      html = render_click(view, "open_config", %{"model" => "too-big"})

      assert html =~ "Over budget"
      # The guard is the disabled submit, not just the copy.
      assert html =~ "disabled"
    end
  end
end
