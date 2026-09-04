defmodule AiroWeb.HomeLiveTest do
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.Usage

  test "renders the gateway overview dashboard", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Overview"
    assert html =~ "Performance monitor"
    assert html =~ "Model posture"
    assert html =~ "Capacity posture"
  end

  test "mounts the chart hooks once there is traffic to plot", %{conn: conn} do
    {:ok, _} =
      Usage.record_usage(%{
        trace_id: "gt_home_chart",
        capability: :chat,
        outcome: :success,
        latency_ms: 42
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#request-volume-chart[phx-hook='PerfChart']")
    assert has_element?(view, "#latency-chart[phx-hook='PerfChart']")
  end

  test "says so plainly when the window has no traffic", %{conn: conn} do
    # Vega derives the axis from the data, so an all-zero window used to plot a
    # flat line against a "NaN" scale. Assert we state the fact instead — and
    # that we don't mount a hook with nothing to draw.
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "No traffic in this window."
    refute has_element?(view, "#request-volume-chart[phx-hook='PerfChart']")
  end
end

defmodule AiroWeb.HomeLiveLifecycleTest do
  # Not async: Presence and the hosts ETS table are node-global.
  use AiroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Airo.Agents.Lifecycle
  alias Airo.Config
  alias Airo.Test.AgentControl

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.hosts_table())
    {:ok, agent} = Config.create_agent(%{host_id: "home-host", control_url: "http://h:4400"})
    %{agent: agent}
  end

  # Tag text is rendered with surrounding whitespace, and "offline" contains
  # "online", so match the tag body exactly but tolerate the whitespace.
  defp tag?(view, text), do: Regex.match?(~r/>\s*#{text}\s*</, render(view))

  test "a lifecycle event flips the host card without waiting for the tick", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "home-host"
    assert html =~ "offline"

    # The channel would track Presence *before* recording connected; mirror that.
    AgentControl.mark_online("home-host")
    Lifecycle.transition("home-host", :connected)
    assert tag?(view, "online")

    Lifecycle.transition("home-host", :stale, meta: %{silent_ms: 47_000})
    assert tag?(view, "stale")

    Lifecycle.transition("home-host", :recovered)
    assert tag?(view, "online")

    # The event is the truth for a drop even while Presence still lists the host.
    Lifecycle.transition("home-host", :disconnected)
    assert tag?(view, "offline")
  end
end
