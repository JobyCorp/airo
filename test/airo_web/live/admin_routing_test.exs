defmodule AiroWeb.AdminRoutingTest do
  @moduledoc "The /admin/routing system classifier settings view (S16)."
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.Config

  test "renders the system classifier settings", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/routing")
    assert html =~ "Classifier model"
    assert html =~ "Tier ladder"
    assert html =~ "Local (Ortex)"
    assert html =~ "Remote (Infinity)"
  end

  test "saving switches the engine, weighting, and ladder", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/routing")

    view
    |> form("#routing-form", %{
      "rs" => %{
        "backend" => "ortex",
        "model" => "nvidia-prompt-task-complexity",
        "input" => "last_user",
        "default_class" => "edge",
        "timeout_ms" => "200",
        "weights" => %{"constraint" => "0.55", "reasoning" => "0.35"},
        "labels" => %{"0" => %{"class" => "deep", "min" => "0.2", "label" => ""}}
      }
    })
    |> render_submit(%{"intent" => "save"})

    s = Config.get_routing_setting()
    assert s.backend == :ortex
    assert s.model == "nvidia-prompt-task-complexity"
    assert s.score == %{"constraint" => 0.55, "reasoning" => 0.35}

    assert [%{"class" => "deep", "min" => 0.2}] =
             Enum.map(s.labels, &Map.take(&1, ["class", "min"]))
  end
end
