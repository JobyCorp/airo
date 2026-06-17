defmodule AiroWeb.HomeLiveTest do
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the gateway overview dashboard", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Overview"
    assert html =~ "Performance monitor"
    assert html =~ "Model posture"
    assert html =~ "Capacity posture"
    assert has_element?(view, "#request-volume-chart[phx-hook='PerfChart']")
    assert has_element?(view, "#latency-chart[phx-hook='PerfChart']")
  end
end
