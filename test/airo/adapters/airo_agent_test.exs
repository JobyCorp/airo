defmodule Airo.Adapters.AiroAgentTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.AiroAgent
  alias Airo.Config.{Deployment, Provider}

  @control "http://agent-host:4400"
  @engine "http://agent-host:51817/v1"

  defp context(fields \\ []) do
    provider =
      struct(
        %Provider{
          name: "jobycorp",
          adapter_type: :airo_agent,
          base_url: @control,
          auth_kind: :none
        },
        Keyword.get(fields, :provider, [])
      )

    Context.new(provider,
      deployment: fields[:deployment],
      opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    )
  end

  describe "management over the control API" do
    test "catalog hits /inventory and surfaces revision provenance" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/inventory"

        Req.Test.json(conn, %{
          "models" => [
            %{
              "id" => "org/repo:Q4",
              "repo" => "org/repo",
              "revision" => "abc123",
              "quant" => "Q4",
              "family" => "qwen3",
              "size_bytes" => 100,
              "ctx_max" => 4096,
              "engine" => "llama_cpp",
              "capabilities" => ["chat"]
            }
          ]
        })
      end)

      assert {:ok, [m]} = AiroAgent.catalog(context())
      assert m.id == "org/repo:Q4"
      assert m.revision == "abc123"
      assert m.quantization == "Q4"
      assert m.context_window == 4096
      assert m.format == "gguf"
    end

    test "inspect_model finds one model by id" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"models" => [%{"id" => "a", "revision" => "r1"}, %{"id" => "b"}]})
      end)

      assert {:ok, %{id: "a", revision: "r1"}} = AiroAgent.inspect_model("a", context())
      assert {:error, :not_found} = AiroAgent.inspect_model("missing", context())
    end

    test "runtime_info merges /running and /gpu" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/running" ->
            Req.Test.json(conn, %{"instances" => [%{"model_id" => "x", "status" => "up"}]})

          "/gpu" ->
            Req.Test.json(conn, %{"available" => true, "vram_used_mb" => 1000})
        end
      end)

      assert {:ok, %{running: [_], gpu: %{"available" => true}}} =
               AiroAgent.runtime_info(context())
    end
  end

  describe "lifecycle control over the agent API" do
    test "load_model POSTs /load with the model and profile" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:posted, conn.method, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"model_id" => "org/repo:Q4", "status" => "loading"})
      end)

      assert {:ok, %{"status" => "loading"}} =
               AiroAgent.load_model("org/repo:Q4", %{"ctx" => 4096}, context())

      assert_received {:posted, "POST", "/load",
                       %{"model" => "org/repo:Q4", "profile" => %{"ctx" => 4096}}}
    end

    test "unload_model POSTs /unload" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:posted, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{"ok" => true}} = AiroAgent.unload_model("org/repo:Q4", context())
      assert_received {:posted, "/unload", %{"model" => "org/repo:Q4"}}
    end
  end

  describe "serving routes to the engine, not the agent" do
    test "chat retargets to the stashed engine base_url" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:served, conn.host, conn.port, conn.request_path})
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "hi"}}]})
      end)

      dep = %Deployment{
        model_name: "org/repo:Q4",
        provider_metadata: %{"serving_base_url" => @engine}
      }

      assert {:ok, _} = AiroAgent.chat(%{"messages" => []}, context(deployment: dep))
      # Engine port + /v1 path — NOT the control port 4400.
      assert_received {:served, "agent-host", 51_817, "/v1/chat/completions"}
    end

    test "a cold model is auto-loaded, then served" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/load" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:loaded, Jason.decode!(body)})
            Req.Test.json(conn, %{"base_url" => @engine, "status" => "loading"})

          "/v1/models" ->
            Req.Test.json(conn, %{"data" => [%{"id" => "org/repo:Q4"}]})

          "/v1/chat/completions" ->
            send(test_pid, {:served, conn.port})
            Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "hi"}}]})
        end
      end)

      dep = %Deployment{model_name: "org/repo:Q4", provider_metadata: %{}}
      assert {:ok, _} = AiroAgent.chat(%{"messages" => []}, context(deployment: dep))
      assert_received {:loaded, %{"model" => "org/repo:Q4"}}
      assert_received {:served, 51_817}
    end

    test "auto-load disabled ⇒ :model_not_loaded" do
      Application.put_env(:airo, :airo_agent_auto_load, false)
      on_exit(fn -> Application.delete_env(:airo, :airo_agent_auto_load) end)

      dep = %Deployment{model_name: "org/repo:Q4", provider_metadata: %{}}

      assert {:error, :model_not_loaded} =
               AiroAgent.chat(%{"messages" => []}, context(deployment: dep))

      assert {:error, :model_not_loaded, :acc} =
               AiroAgent.stream(%{}, context(deployment: dep), :acc, fn _, a -> a end)
    end

    test "a load that never becomes ready ⇒ :load_timeout" do
      Application.put_env(:airo, :airo_agent_load_timeout_ms, 30)
      Application.put_env(:airo, :airo_agent_load_poll_ms, 5)

      on_exit(fn ->
        Application.delete_env(:airo, :airo_agent_load_timeout_ms)
        Application.delete_env(:airo, :airo_agent_load_poll_ms)
      end)

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/load" -> Req.Test.json(conn, %{"base_url" => @engine, "status" => "loading"})
          # Never ready: 503 loading.
          "/v1/models" -> Plug.Conn.send_resp(conn, 503, ~s({"status":"loading model"}))
        end
      end)

      dep = %Deployment{model_name: "org/repo:Q4", provider_metadata: %{}}

      assert {:error, :load_timeout} =
               AiroAgent.chat(%{"messages" => []}, context(deployment: dep))
    end
  end
end
