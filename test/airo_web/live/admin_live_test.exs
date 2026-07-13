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

  defp stub_ollama_native do
    Req.Test.stub(Airo.TestStub, fn
      %{request_path: "/api/show"} = conn ->
        Req.Test.json(conn, %{
          "modelfile" => "FROM moondream:latest",
          "parameters" => "temperature 0.2",
          "template" => "{{ .Prompt }}",
          "license" => "Apache-2.0",
          "details" => %{
            "format" => "gguf",
            "family" => "moondream",
            "families" => ["moondream"],
            "parameter_size" => "1.6B",
            "quantization_level" => "Q4_K_M"
          },
          "model_info" => %{
            "general.architecture" => "moondream",
            "moondream.context_length" => 2048
          }
        })

      %{request_path: "/api/version"} = conn ->
        Req.Test.json(conn, %{"version" => "0.5.1"})

      %{request_path: "/api/ps"} = conn ->
        Req.Test.json(conn, %{
          "models" => [
            %{
              "model" => "moondream:latest",
              "size" => 1_900_000_000,
              "details" => %{"family" => "moondream"}
            }
          ]
        })
    end)
  end

  defp stub_infinity_native do
    Req.Test.stub(Airo.TestStub, fn
      %{request_path: "/models"} = conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "BAAI/bge-reranker-v2-m3",
              "stats" => %{
                "queue_fraction" => 0.0,
                "queue_absolute" => 0,
                "results_pending" => 0,
                "batch_size" => 32
              },
              "object" => "model",
              "owned_by" => "infinity",
              "created" => 1_781_703_287,
              "backend" => "torch",
              "capabilities" => ["rerank"]
            }
          ],
          "object" => "list"
        })

      %{request_path: "/metrics"} = conn ->
        Req.Test.text(
          conn,
          """
          http_requests_total{handler="/rerank",method="POST",status="2xx"} 250.0
          http_request_duration_seconds_count{handler="/rerank",method="POST"} 250.0
          http_request_duration_seconds_sum{handler="/rerank",method="POST"} 8.0
          """
        )
    end)
  end

  describe "providers" do
    test "create, list, and delete", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/providers/new")

      view
      |> form("#provider-form",
        provider: %{
          name: "local-vllm",
          adapter_type: "vllm",
          base_url: "http://up/v1",
          auth_kind: "none"
        }
      )
      |> render_submit()

      provider = Config.get_provider_by_name("local-vllm")
      {path, _flash} = assert_redirect(view)
      assert path == ~p"/admin/providers/#{provider.id}"

      {:ok, view, html} = live(conn, ~p"/admin/providers")
      assert html =~ "local-vllm"

      view |> element("button[phx-value-id='#{provider.id}']") |> render_click()
      refute render(view) =~ "local-vllm"
    end

    test "new provider link opens the routed create form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/providers")

      {:ok, _view, html} =
        view
        |> element("a", "New provider")
        |> render_click()
        |> follow_redirect(conn, ~p"/admin/providers/new")

      assert html =~ "New provider"
      assert html =~ "provider-form"
    end

    test "shows validation errors for an invalid provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/providers/new")

      html =
        view |> form("#provider-form", provider: %{name: "", base_url: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "flags a scheme-less base_url inline before it can be saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/providers/new")

      # phx-change validation: typing a bad base_url surfaces the error inline,
      # so a probe-able-but-invalid provider never reaches the database.
      html =
        view
        |> form("#provider-form", provider: %{name: "Local", base_url: "localhost:4000"})
        |> render_change()

      assert html =~ "must be an absolute http(s) URL"

      view
      |> form("#provider-form",
        provider: %{name: "Local", adapter_type: "vllm", base_url: "localhost:4000"}
      )
      |> render_submit()

      refute Config.get_provider_by_name("Local")
    end

    test "creates an inline provider credential secret", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/providers/new")

      view
      |> form("#provider-form",
        provider: %{
          name: "Unsloth test",
          adapter_type: "unsloth",
          base_url: "https://unsloth.local.joby.gg/v1",
          auth_kind: "api_key",
          new_credential_name: "Unsloth test API key",
          new_credential_value: "secret-token"
        }
      )
      |> render_submit()

      provider = Config.get_provider_by_name("Unsloth test")
      secret = Config.get_secret_by_name("Unsloth test API key")
      {path, _flash} = assert_redirect(view)

      assert path == ~p"/admin/providers/#{provider.id}"
      assert provider.credential_id == secret.id

      {:ok, _view, html} = live(conn, ~p"/admin/providers")
      assert html =~ "Unsloth test API key"
      refute html =~ "secret-token"
    end

    test "opens provider inventory and syncs deployment metadata", %{conn: conn} do
      stub_infinity_native()

      {:ok, provider} =
        Config.create_provider(%{
          name: "infinity-detail",
          adapter_type: :infinity,
          base_url: "http://infinity:7997",
          auth_kind: :none
        })

      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: provider.id,
          model_name: "BAAI/bge-reranker-v2-m3",
          capabilities: [:rerank]
        })

      {:ok, view, html} = live(conn, ~p"/admin/providers/#{provider.id}")

      assert html =~ "Local catalog"
      assert html =~ "BAAI/bge-reranker-v2-m3"
      assert html =~ "torch"
      assert has_element?(view, "#provider-deployments")
      assert has_element?(view, "#provider-catalog")

      html =
        view
        |> element("button[phx-click='sync_deployment'][phx-value-id='#{deployment.id}']")
        |> render_click()

      assert html =~ "Provider metadata synced."
      assert html =~ "bge"
      assert html =~ "rerank"
      assert html =~ "32"
    end
  end

  describe "client keys" do
    test "minting shows the raw key once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/keys/new")

      html =
        view
        |> form("#key-form", client_key: %{name: "orchester", allowed_aliases: "*"})
        |> render_submit()

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

      {:ok, view, _html} = live(conn, ~p"/admin/aliases/new")

      view
      |> form("#alias-form",
        alias: %{name: "chat-deep", capability: "chat", strategy: "priority"}
      )
      |> render_submit()

      alias_ = Config.get_alias_by_name("chat-deep")
      assert alias_
      {path, _flash} = assert_redirect(view)
      assert path == ~p"/admin/aliases/#{alias_.id}/edit"

      {:ok, view, _html} = live(conn, ~p"/admin/aliases/#{alias_.id}/edit")

      html =
        view
        |> form("#alias-candidate-form",
          candidate: %{deployment_id: deployment.id, weight: "100", priority: "0"}
        )
        |> render_submit()

      assert html =~ "qwen"
      assert [_candidate] = Config.get_alias_with_candidates!(alias_.id).candidates
    end
  end

  describe "deployments" do
    test "renders capabilities as visible checkbox choices", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/deployments/new")

      assert has_element?(view, "#deployment_capabilities-group")

      assert has_element?(
               view,
               "input[type='checkbox'][name='deployment[capabilities][]'][value='chat']"
             )

      refute has_element?(view, "select[name='deployment[capabilities][]']")
    end

    test "the model field becomes a picker of the provider's upstream models", %{conn: conn} do
      Req.Test.stub(Airo.TestStub, fn upstream ->
        Req.Test.json(upstream, %{"data" => [%{"id" => "qwen3.5-9b"}, %{"id" => "nomic-embed"}]})
      end)

      p = provider("vllm-models")
      {:ok, view, _html} = live(conn, ~p"/admin/deployments/new")

      html =
        view
        |> form("#deployment-form", deployment: %{provider_id: p.id})
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
      {:ok, view, _html} = live(conn, ~p"/admin/deployments/new")

      html = view |> form("#deployment-form", deployment: %{provider_id: p.id}) |> render_change()
      assert html =~ "reports no models"
    end

    test "falls back to free text with a hint when the upstream can't be listed", %{conn: conn} do
      Req.Test.stub(Airo.TestStub, fn upstream ->
        Req.Test.transport_error(upstream, :econnrefused)
      end)

      p = provider("vllm-down")
      {:ok, view, _html} = live(conn, ~p"/admin/deployments/new")

      html =
        view
        |> form("#deployment-form", deployment: %{provider_id: p.id})
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

      {:ok, view, _html} = live(conn, ~p"/admin/deployments/new")

      view
      |> form("#deployment-form",
        deployment: %{
          provider_id: provider.id,
          model_id: model.id,
          model_name: "qwen3.5-9b",
          capabilities: ["chat"]
        }
      )
      |> render_submit()

      assert {_path, _flash} = assert_redirect(view)
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
      assert detail_html =~ "Deployment guidance"
      assert detail_html =~ "Version performance"
      assert detail_html =~ "Routing participation"
      assert detail_html =~ "Recent traces"
      assert detail_html =~ "Candidate"
      assert detail_html =~ "gt_model_trace"
    end

    test "creates model metadata from the shelf", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/models/new")

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

      model = Config.get_model_by_upstream_id("mistral-small")
      {path, _flash} = assert_redirect(view)

      assert path == ~p"/admin/models/#{model.id}"

      {:ok, _view, html} = live(conn, path)
      assert html =~ "Mistral local"
      assert model
    end

    test "syncs Ollama metadata into the model detail page", %{conn: conn} do
      stub_ollama_native()

      {:ok, provider} =
        Config.create_provider(%{
          name: "ollama-vision",
          adapter_type: :ollama,
          base_url: "http://ollama:11434/v1",
          auth_kind: :none
        })

      {:ok, deployment} =
        Config.create_deployment(%{
          provider_id: provider.id,
          model_name: "moondream:latest",
          capabilities: [:chat, :vision]
        })

      model = Config.get_model_by_upstream_id("moondream:latest")
      {:ok, view, html} = live(conn, ~p"/admin/models/#{model.id}")

      assert html =~ "Provider metadata"

      assert has_element?(
               view,
               "button[phx-click='sync_deployment'][phx-value-id='#{deployment.id}']"
             )

      refute html =~ "Q4_K_M"

      html =
        view
        |> element("button[phx-click='sync_deployment'][phx-value-id='#{deployment.id}']")
        |> render_click()

      assert html =~ "Provider metadata synced."
      assert html =~ "0.5.1"
      assert html =~ "moondream"
      assert html =~ "1.6B"
      assert html =~ "Q4_K_M"
      assert html =~ "gguf"
      assert html =~ "2048"
      assert html =~ "yes"
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
        |> element("button[phx-click='trace'][phx-value-id='gt_trace_target']")
        |> render_click()

      assert html =~ "gt_trace_target"
      refute html =~ "gt_trace_other"
    end
  end
end
