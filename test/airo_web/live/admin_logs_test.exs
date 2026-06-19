defmodule AiroWeb.AdminLogsTest do
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.Logs

  test "renders events and narrows by the kind filter", %{conn: conn} do
    :ok =
      Logs.record(%{
        kind: :route_prediction,
        level: :info,
        trace_id: "gt_pred",
        summary: "predicted-deep-marker",
        alias_name: "chat",
        data: %{"predicted_class" => "deep"}
      })

    :ok =
      Logs.record(%{
        kind: :health,
        level: :warning,
        trace_id: "gt_health",
        summary: "health-down-marker",
        data: %{"status" => "down"}
      })

    {:ok, view, html} = live(conn, ~p"/admin/logs")
    assert html =~ "predicted-deep-marker"
    assert html =~ "health-down-marker"

    html = view |> form("#logs-filters", filters: %{kind: "health"}) |> render_change()
    assert html =~ "health-down-marker"
    refute html =~ "predicted-deep-marker"
  end
end
