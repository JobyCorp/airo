defmodule Airo.Adapters.UnslothTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.Unsloth
  alias Airo.Config.{Deployment, Provider}

  defp context(fields \\ []) do
    provider =
      struct(
        %Provider{
          name: "unsloth-mini",
          adapter_type: :unsloth,
          base_url: "http://unsloth:8000/v1",
          auth_kind: :none
        },
        Keyword.get(fields, :provider, [])
      )

    Context.new(provider,
      deployment: fields[:deployment],
      opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    )
  end

  defp models_payload do
    %{
      "object" => "list",
      "data" => [
        %{
          "id" => "unsloth/qwen3.5-9b",
          "object" => "model",
          "created" => 1_781_702_879,
          "owned_by" => "unsloth",
          "root" => "unsloth/Qwen3.5-9B-AWQ",
          "max_model_len" => 32_768
        }
      ]
    }
  end

  test "chat uses the OpenAI-compatible /v1 surface" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "hi"}, "finish_reason" => "stop"}]
      })
    end)

    ctx = context(deployment: %Deployment{model_name: "unsloth/qwen3.5-9b"})
    assert {:ok, _} = Unsloth.chat(%{"model" => "chat-local", "messages" => []}, ctx)
    assert_received {:request, "/v1/chat/completions", %{"model" => "unsloth/qwen3.5-9b"}}
  end

  test "catalog uses /v1/models and keeps Unsloth model ownership" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path})
      Req.Test.json(conn, models_payload())
    end)

    assert {:ok, [model]} = Unsloth.catalog(context())
    assert model.id == "unsloth/qwen3.5-9b"
    assert model.owned_by == "unsloth"
    assert model.context_window == 32_768
    assert model.family == "qwen3.5"
    assert model.parameter_size == "9B"
    assert model.quantization == "AWQ"
    assert_received {:request, "GET", "/v1/models"}
  end

  test "runtime_info checks root /metrics while preserving the /v1 models base" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/v1/models"} = conn ->
        Req.Test.json(conn, models_payload())

      %{request_path: "/metrics"} = conn ->
        Req.Test.text(
          conn,
          """
          vllm:num_requests_running{engine="0",model_name="unsloth/qwen3.5-9b"} 1.0
          vllm:num_requests_waiting{engine="0",model_name="unsloth/qwen3.5-9b"} 0.0
          """
        )
    end)

    assert {:ok, %{running: [running], metrics: %{"unsloth/qwen3.5-9b" => metrics}}} =
             Unsloth.runtime_info(context())

    assert running.id == "unsloth/qwen3.5-9b"
    assert metrics["num_requests_running"] == 1.0
    assert metrics["num_requests_waiting"] == 0.0
  end
end
