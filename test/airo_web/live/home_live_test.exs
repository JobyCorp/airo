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
