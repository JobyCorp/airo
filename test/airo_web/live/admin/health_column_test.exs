defmodule AiroWeb.Admin.HealthColumnTest do
  @moduledoc """
  Smoke tests for the Sprint A health-visibility column: the admin Deployments
  and Providers pages must render the `health_status` composite reflecting the
  ETS-backed `Airo.Health` status.
  """
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.Config
  alias Airo.Health
  alias Airo.Health.HealthEvent
  alias Airo.Repo

  setup do
    {:ok, p} =
      Config.create_provider(%{
        name: "phc-#{System.unique_integer([:positive])}",
        adapter_type: :ollama,
        base_url: "http://phc/v1",
        auth_kind: :none
      })

    {:ok, d} =
      Config.create_deployment(%{provider_id: p.id, model_name: "mhc", capabilities: [:chat]})

    %{provider: p, deployment: d}
  end

  test "deployments admin renders the health pill as down", %{conn: conn, deployment: d} do
    Health.mark(d.id, :down)
    {:ok, _view, html} = live(conn, "/admin/deployments")

    assert html =~ "Health"
    assert html =~ "AiroWeb.CompositeComponents.health_status"
    assert html =~ "text-error"
  end

  test "deployments admin renders recent health transitions", %{
    conn: conn,
    provider: p,
    deployment: d
  } do
    {:ok, _event} =
      Repo.insert(%HealthEvent{
        provider_id: p.id,
        deployment_id: d.id,
        status: :down,
        source: :probe,
        reason: "http_500"
      })

    {:ok, view, html} = live(conn, "/admin/deployments")

    assert has_element?(view, "#health-events")
    assert html =~ "Health transitions"
    assert html =~ "http_500"
  end

  test "providers admin aggregates deployment health to up", %{conn: conn, deployment: d} do
    Health.mark(d.id, :up)
    {:ok, _view, html} = live(conn, "/admin/providers")

    assert html =~ "Health"
    assert html =~ "AiroWeb.CompositeComponents.health_status"
    assert html =~ "text-success"
  end
end
