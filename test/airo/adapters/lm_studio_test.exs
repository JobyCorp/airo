defmodule Airo.Adapters.LMStudioTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.LMStudio
  alias Airo.Config.{Deployment, Provider}

  defp context(stub, fields \\ []) do
    provider =
      struct(
        %Provider{
          name: "lmstudio-mini",
          adapter_type: :lmstudio,
          base_url: "http://lmstudio:1234/v1",
          auth_kind: :none
        },
        Keyword.get(fields, :provider, [])
      )

    Context.new(provider,
      deployment: fields[:deployment],
      opts: [req_options: [plug: {Req.Test, stub}]]
    )
  end

  defp model_payload do
    %{
      "models" => [
        %{
          "type" => "llm",
          "publisher" => "google",
          "key" => "google/gemma-4-26b-a4b",
          "display_name" => "Gemma 4 26B A4B",
          "architecture" => "gemma4",
          "quantization" => %{"name" => "Q4_K_M", "bits_per_weight" => 4},
          "size_bytes" => 17_990_911_801,
          "params_string" => "26B-A4B",
          "loaded_instances" => [
            %{
              "id" => "google/gemma-4-26b-a4b",
              "config" => %{
                "context_length" => 4096,
                "eval_batch_size" => 512,
                "parallel" => 4,
                "flash_attention" => true
              }
            }
          ],
          "max_context_length" => 262_144,
          "format" => "gguf",
          "capabilities" => %{
            "vision" => true,
            "trained_for_tool_use" => true,
            "reasoning" => %{"allowed_options" => ["off", "on"], "default" => "on"}
          },
          "description" => nil,
          "variants" => ["google/gemma-4-26b-a4b@q4_k_m"],
          "selected_variant" => "google/gemma-4-26b-a4b@q4_k_m"
        }
      ]
    }
  end

  describe "inference delegation" do
    test "chat still uses the OpenAI-compatible /v1 surface" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.request_path, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "hi"}, "finish_reason" => "stop"}]
        })
      end)

      ctx = context(__MODULE__, deployment: %Deployment{model_name: "google/gemma-4-26b-a4b"})
      assert {:ok, _} = LMStudio.chat(%{"model" => "chat-local", "messages" => []}, ctx)
      assert_received {:request, "/v1/chat/completions", %{"model" => "google/gemma-4-26b-a4b"}}
    end
  end

  describe "catalog/1" do
    test "uses native /api/v1/models and normalizes local model metadata" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})
        Req.Test.json(conn, model_payload())
      end)

      assert {:ok, [model]} = LMStudio.catalog(context(__MODULE__))
      assert model.id == "google/gemma-4-26b-a4b"
      assert model.family == "gemma4"
      assert model.publisher == "google"
      assert model.quantization == "Q4_K_M"
      assert model.parameter_size == "26B-A4B"
      assert model.context_window == 4096
      assert model.max_context_window == 262_144
      assert model.vision == true
      assert_received {:request, "GET", "/api/v1/models"}
    end
  end

  describe "inspect_model/2" do
    test "finds a model by key or selected variant and returns rich metadata" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, model_payload())
      end)

      assert {:ok, metadata} =
               LMStudio.inspect_model("google/gemma-4-26b-a4b@q4_k_m", context(__MODULE__))

      assert metadata.id == "google/gemma-4-26b-a4b"
      assert metadata.selected_variant == "google/gemma-4-26b-a4b@q4_k_m"
      assert metadata.architecture == "gemma4"
      assert metadata.context_window == 4096
      assert metadata.loaded_instances |> hd() |> get_in(["config", "parallel"]) == 4
    end
  end

  describe "pull_model/2" do
    test "uses native /api/v1/models/download" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"job_id" => "job_123", "status" => "downloading"})
      end)

      assert {:ok, %{"status" => "downloading"}} =
               LMStudio.pull_model(
                 %{"model" => "google/gemma-4-26b-a4b", "quantization" => "Q4_K_M"},
                 context(__MODULE__)
               )

      assert_received {:request, "/api/v1/models/download",
                       %{"model" => "google/gemma-4-26b-a4b", "quantization" => "Q4_K_M"}}
    end
  end

  describe "runtime_info/1" do
    test "reports loaded model instances as running models" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, model_payload())
      end)

      assert {:ok, %{running: [running]}} = LMStudio.runtime_info(context(__MODULE__))
      assert running.id == "google/gemma-4-26b-a4b"
      assert running.loaded_instances != []
    end
  end
end
