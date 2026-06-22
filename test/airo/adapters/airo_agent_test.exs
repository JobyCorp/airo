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

    test "serving an unloaded model errors with :model_not_loaded" do
      dep = %Deployment{model_name: "org/repo:Q4", provider_metadata: %{}}

      assert {:error, :model_not_loaded} =
               AiroAgent.chat(%{"messages" => []}, context(deployment: dep))

      assert {:error, :model_not_loaded, :acc} =
               AiroAgent.stream(%{}, context(deployment: dep), :acc, fn _, a -> a end)
    end
  end
end
