defmodule AiroWeb.AdminLogsTest do
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.Logs

  test "renders structured events and narrows by the kind filter", %{conn: conn} do
    :ok =
      Logs.record(%{
        kind: :route_prediction,
        level: :info,
        trace_id: "gt_pred",
        summary: "raw summary string",
        alias_name: "chat-marker-alias",
        data: %{
          "predicted_class" => "deep",
          "mode" => "shadow",
          "scores" => %{"deep" => 0.91},
          "latency_ms" => 12
        }
      })

    :ok =
      Logs.record(%{
        kind: :health,
        level: :warning,
        trace_id: "gt_health",
        summary: "raw health summary",
        data: %{"status" => "down", "source" => "dispatch"}
      })

    {:ok, view, html} = live(conn, ~p"/admin/logs")
    # structured fields render, not the raw summary string
    assert html =~ "chat-marker-alias"
    assert html =~ "deep"
    assert html =~ "down"

    html = view |> form("#logs-filters", filters: %{kind: "health"}) |> render_change()
    assert html =~ "down"
    refute html =~ "chat-marker-alias"
  end
end
