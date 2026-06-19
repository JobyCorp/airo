defmodule AiroWeb.AdminTraceTest do
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.{Logs, Usage}

  test "stitches usage + log events for a trace into one timeline", %{conn: conn} do
    {:ok, _} =
      Usage.record_usage(%{
        trace_id: "gt_t1",
        capability: :chat,
        outcome: :success,
        alias_name: "chat",
        latency_ms: 42
      })

    :ok =
      Logs.record(%{
        kind: :route_prediction,
        level: :info,
        trace_id: "gt_t1",
        summary: "predicted-deep-trace-marker",
        alias_name: "chat",
        data: %{}
      })

    {:ok, _view, html} = live(conn, ~p"/admin/logs/gt_t1")

    assert html =~ "predicted-deep-trace-marker"
    assert html =~ "latency=42ms"
    assert html =~ "gt_t1"
  end

  test "empty state for an unknown trace", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/logs/gt_unknown")
    assert html =~ "No events for this trace"
  end
end
