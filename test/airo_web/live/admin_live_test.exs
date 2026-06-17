defmodule AiroWeb.AdminLiveTest do
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.Config

  defp provider(name \\ "vllm-1") do
    {:ok, p} =
      Config.create_provider(%{
        name: name,
        adapter_type: :vllm,
        base_url: "http://x/v1",
        auth_kind: :none
      })

    p
  end

  describe "providers" do
    test "create, list, and delete", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/providers")

      view |> element("button", "New provider") |> render_click()

      html =
        view
        |> form("form",
          provider: %{
            name: "local-vllm",
            adapter_type: "vllm",
            base_url: "http://up/v1",
            auth_kind: "none"
          }
        )
        |> render_submit()

      assert html =~ "local-vllm"

      provider = Config.get_provider_by_name("local-vllm")
      view |> element("button[phx-value-id='#{provider.id}']", "Delete") |> render_click()
      refute render(view) =~ "local-vllm"
    end

    test "shows validation errors for an invalid provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/providers")
      view |> element("button", "New provider") |> render_click()

      html = view |> form("form", provider: %{name: "", base_url: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  describe "client keys" do
    test "minting shows the raw key once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/keys")

      html =
        view
        |> form("form", client_key: %{name: "orchester", allowed_aliases: "*"})
        |> render_submit()

      assert html =~ "orchester"
      assert html =~ "airo_"
      assert Config.list_client_keys() |> Enum.any?(&(&1.name == "orchester"))
    end
  end

  describe "aliases" do
    test "create an alias, then add a routing candidate", %{conn: conn} do
      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: provider().id,
          model_name: "qwen",
          capabilities: [:chat]
        })

      {:ok, view, _html} = live(conn, ~p"/admin/aliases")

      view |> element("button", "New alias") |> render_click()

      view
      |> form("form", alias: %{name: "chat-deep", capability: "chat", strategy: "priority"})
      |> render_submit()

      alias_ = Config.get_alias_by_name("chat-deep")
      assert alias_

      html =
        view
        |> form("form[phx-submit=add_candidate]",
          candidate: %{deployment_id: deployment.id, weight: "100", priority: "0"}
        )
        |> render_submit()

      assert html =~ "qwen"
      assert [_candidate] = Config.get_alias_with_candidates!(alias_.id).candidates
    end
  end

  describe "deployments" do
    test "the model field becomes a picker of the provider's upstream models", %{conn: conn} do
      Req.Test.stub(Airo.TestStub, fn upstream ->
        Req.Test.json(upstream, %{"data" => [%{"id" => "qwen3.5-9b"}, %{"id" => "nomic-embed"}]})
      end)

      p = provider("vllm-models")
      {:ok, view, _html} = live(conn, ~p"/admin/deployments")

      view |> element("button", "New deployment") |> render_click()

      html =
        view
        |> form("form", deployment: %{provider_id: p.id})
        |> render_change()

      assert html =~ ~s(<select)
      assert html =~ "qwen3.5-9b"
      assert html =~ "nomic-embed"
    end

    test "notes when a reachable provider reports an empty catalog", %{conn: conn} do
      Req.Test.stub(Airo.TestStub, fn upstream ->
        Req.Test.json(upstream, %{"data" => []})
      end)

      p = provider("vllm-empty")
      {:ok, view, _html} = live(conn, ~p"/admin/deployments")

      view |> element("button", "New deployment") |> render_click()

      html = view |> form("form", deployment: %{provider_id: p.id}) |> render_change()
      assert html =~ "reports no models"
    end

    test "falls back to free text with a hint when the upstream can't be listed", %{conn: conn} do
      Req.Test.stub(Airo.TestStub, fn upstream ->
        Req.Test.transport_error(upstream, :econnrefused)
      end)

      p = provider("vllm-down")
      {:ok, view, _html} = live(conn, ~p"/admin/deployments")

      view |> element("button", "New deployment") |> render_click()

      html =
        view
        |> form("form", deployment: %{provider_id: p.id})
        |> render_change()

      assert html =~ "Couldn&#39;t reach the provider" or html =~ "Couldn't reach the provider"
    end
  end

  describe "usage" do
    test "renders the usage view", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/usage")
      assert html =~ "Usage"
      assert html =~ "Total cost"
    end
  end
end
