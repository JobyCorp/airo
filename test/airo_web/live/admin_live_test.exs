defmodule AiroWeb.AdminLiveTest do
  use AiroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Airo.{Config, Usage}

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

    test "can attach a deployment to an existing shelf model", %{conn: conn} do
      provider = provider("vllm-shelf")

      {:ok, model} =
        Config.create_model(%{
          display_name: "Qwen evaluation",
          upstream_model_id: "qwen3.5-9b",
          status: :evaluating
        })

      {:ok, view, _html} = live(conn, ~p"/admin/deployments")

      view |> element("button", "New deployment") |> render_click()

      html =
        view
        |> form("form",
          deployment: %{
            provider_id: provider.id,
            model_id: model.id,
            model_name: "qwen3.5-9b",
            capabilities: ["chat"]
          }
        )
        |> render_submit()

      assert html =~ "qwen3.5-9b"
      assert Config.list_deployments() |> Enum.any?(&(&1.model_id == model.id))
    end
  end

  describe "model shelf" do
    test "renders aggregate model posture and opens detail", %{conn: conn} do
      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: provider("model-host").id,
          model_name: "qwen3.5-9b",
          capabilities: [:chat],
          class: :deep
        })

      {:ok, _} =
        Usage.record_usage(%{
          trace_id: "gt_model_trace",
          deployment_id: deployment.id,
          request_model: "chat-deep",
          alias_name: "chat-deep",
          capability: :chat,
          latency_ms: 123,
          outcome: :success
        })

      {:ok, view, html} = live(conn, ~p"/admin/models")

      assert html =~ "Model Shelf"
      assert html =~ "qwen3.5-9b"
      assert html =~ "123 ms"
      assert has_element?(view, "#models")

      model = Config.get_model_by_upstream_id("qwen3.5-9b")
      {:ok, _view, detail_html} = live(conn, ~p"/admin/models/#{model.id}")

      assert detail_html =~ "Deployment copies"
      assert detail_html =~ "Routing participation"
      assert detail_html =~ "Recent traces"
      assert detail_html =~ "gt_model_trace"
    end

    test "creates model metadata from the shelf", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/models")

      view |> element("button", "New model") |> render_click()

      html =
        view
        |> form("#model-form",
          model: %{
            display_name: "Mistral local",
            upstream_model_id: "mistral-small",
            family: "mistral",
            version: "small",
            status: "evaluating"
          }
        )
        |> render_submit()

      assert html =~ "Mistral local"
      assert Config.get_model_by_upstream_id("mistral-small")
    end
  end

  describe "usage" do
    test "renders the usage view", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/usage")
      assert html =~ "Usage"
      assert has_element?(view, "#usage-filters")
      assert html =~ "Trace"
      assert html =~ "Error rate"
    end

    test "filters usage records by outcome", %{conn: conn} do
      {:ok, _} =
        Usage.record_usage(%{
          trace_id: "gt_success_row",
          request_model: "chat-ok",
          capability: :chat,
          outcome: :success
        })

      {:ok, _} =
        Usage.record_usage(%{
          trace_id: "gt_error_row",
          request_model: "chat-error",
          capability: :chat,
          outcome: :error,
          error_code: "model_not_found",
          http_status: 404
        })

      {:ok, view, _html} = live(conn, ~p"/admin/usage")
      assert render(view) =~ "gt_error_row"
      assert render(view) =~ "gt_success_row"

      html =
        view
        |> form("#usage-filters", filters: %{outcome: "error"})
        |> render_change()

      assert html =~ "gt_error_row"
      refute html =~ "gt_success_row"
    end

    test "filters usage records by trace action", %{conn: conn} do
      {:ok, _} =
        Usage.record_usage(%{
          trace_id: "gt_trace_target",
          request_model: "chat-target",
          capability: :chat,
          outcome: :success
        })

      {:ok, _} =
        Usage.record_usage(%{
          trace_id: "gt_trace_other",
          request_model: "chat-other",
          capability: :chat,
          outcome: :success
        })

      {:ok, view, _html} = live(conn, ~p"/admin/usage")

      html =
        view
        |> element("button[phx-value-id='gt_trace_target']", "Trace")
        |> render_click()

      assert html =~ "gt_trace_target"
      refute html =~ "gt_trace_other"
    end
  end
end
