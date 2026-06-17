defmodule Airo.Adapters.OllamaTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.Ollama
  alias Airo.Config.{Deployment, Provider}

  defp context(stub, fields \\ []) do
    provider =
      struct(
        %Provider{
          name: "ollama-mini",
          adapter_type: :ollama,
          base_url: "http://ollama:11434/v1",
          auth_kind: :none
        },
        Keyword.get(fields, :provider, [])
      )

    Context.new(provider,
      deployment: fields[:deployment],
      opts: [req_options: [plug: {Req.Test, stub}]]
    )
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

      ctx = context(__MODULE__, deployment: %Deployment{model_name: "llama3.2"})
      assert {:ok, _} = Ollama.chat(%{"model" => "chat-local", "messages" => []}, ctx)
      assert_received {:request, "/v1/chat/completions", %{"model" => "llama3.2"}}
    end
  end

  describe "catalog/1" do
    test "uses native /api/tags and normalizes local model metadata" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})

        Req.Test.json(conn, %{
          "models" => [
            %{
              "name" => "llama3.2:3b",
              "modified_at" => "2026-06-17T10:00:00Z",
              "size" => 2_017_000_000,
              "digest" => "sha256:abc",
              "details" => %{
                "format" => "gguf",
                "family" => "llama",
                "families" => ["llama"],
                "parameter_size" => "3B",
                "quantization_level" => "Q4_K_M"
              }
            }
          ]
        })
      end)

      assert {:ok, [model]} = Ollama.catalog(context(__MODULE__))
      assert model.id == "llama3.2:3b"
      assert model.family == "llama"
      assert model.quantization == "Q4_K_M"
      assert model.parameter_size == "3B"
      assert_received {:request, "GET", "/api/tags"}
    end
  end

  describe "inspect_model/2" do
    test "uses native /api/show and extracts model details" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.request_path, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "modelfile" => "FROM llama3.2:3b",
          "parameters" => "temperature 0.7",
          "template" => "{{ .Prompt }}",
          "license" => "MIT",
          "details" => %{
            "format" => "gguf",
            "family" => "llama",
            "families" => ["llama"],
            "parameter_size" => "3B",
            "quantization_level" => "Q4_K_M"
          },
          "model_info" => %{
            "general.architecture" => "llama",
            "llama.context_length" => 131_072
          }
        })
      end)

      assert {:ok, metadata} = Ollama.inspect_model("llama3.2:3b", context(__MODULE__))
      assert metadata.architecture == "llama"
      assert metadata.context_window == 131_072
      assert metadata.modelfile == "FROM llama3.2:3b"
      assert_received {:request, "/api/show", %{"model" => "llama3.2:3b"}}
    end
  end

  describe "pull_model/2" do
    test "uses native /api/pull with stream disabled by default" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"status" => "success"})
      end)

      assert {:ok, %{"status" => "success"}} =
               Ollama.pull_model(%{"model" => "llama3.2:3b"}, context(__MODULE__))

      assert_received {:request, "/api/pull", %{"model" => "llama3.2:3b", "stream" => false}}
    end
  end

  describe "runtime_info/1" do
    test "combines Ollama version and running models" do
      Req.Test.stub(__MODULE__, fn
        %{request_path: "/api/version"} = conn ->
          Req.Test.json(conn, %{"version" => "0.5.1"})

        %{request_path: "/api/ps"} = conn ->
          Req.Test.json(conn, %{
            "models" => [
              %{
                "model" => "llama3.2:3b",
                "size" => 2_017_000_000,
                "details" => %{"family" => "llama"}
              }
            ]
          })
      end)

      assert {:ok, %{version: "0.5.1", running: [running]}} =
               Ollama.runtime_info(context(__MODULE__))

      assert running.id == "llama3.2:3b"
      assert running.family == "llama"
    end
  end
end
