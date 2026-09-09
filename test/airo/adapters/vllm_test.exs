defmodule Airo.Adapters.VLLMTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.VLLM
  alias Airo.Config.{Deployment, Provider}

  defp context(stub, fields \\ []) do
    provider =
      struct(
        %Provider{
          name: "vllm-mini",
          adapter_type: :vllm,
          base_url: "http://vllm:8000/v1",
          auth_kind: :none
        },
        Keyword.get(fields, :provider, [])
      )

    Context.new(provider,
      deployment: fields[:deployment],
      opts: [req_options: [plug: {Req.Test, stub}]]
    )
  end

  defp models_payload do
    %{
      "object" => "list",
      "data" => [
        %{
          "id" => "qwen3.5-9b",
          "object" => "model",
          "created" => 1_781_702_879,
          "owned_by" => "vllm",
          "root" => "QuantTrio/Qwen3.5-9B-AWQ",
          "parent" => nil,
          "max_model_len" => 16_384,
          "permission" => [
            %{
              "id" => "modelperm-test",
              "allow_sampling" => true,
              "allow_logprobs" => true
            }
          ]
        }
      ]
    }
  end

  defp metrics_body do
    """
    # HELP vllm:num_requests_running Number of requests in model execution batches.
    # TYPE vllm:num_requests_running gauge
    vllm:num_requests_running{engine="0",model_name="qwen3.5-9b"} 1.0
    vllm:num_requests_waiting{engine="0",model_name="qwen3.5-9b"} 2.0
    vllm:kv_cache_usage_perc{engine="0",model_name="qwen3.5-9b"} 0.42
    vllm:prompt_tokens_total{engine="0",model_name="qwen3.5-9b"} 1000.0
    vllm:generation_tokens_total{engine="0",model_name="qwen3.5-9b"} 250.0
    vllm:num_preemptions_total{engine="0",model_name="qwen3.5-9b"} 3.0
    vllm:request_success_total{engine="0",finished_reason="stop",model_name="qwen3.5-9b"} 9.0
    vllm:request_success_total{engine="0",finished_reason="length",model_name="qwen3.5-9b"} 1.0
    """
  end

  # A trimmed capture of the real exposition from the speculating GLM slot on
  # sparky:8081 (2026-09-09), counters intact. `_created` lines are timestamps,
  # not readings, and are here to prove they are ignored. The per-position
  # samples sum to the accepted total, as they do on the wire.
  defp speculative_metrics_body do
    """
    # HELP vllm:spec_decode_num_drafts_total Number of speculative draft rounds.
    # TYPE vllm:spec_decode_num_drafts_total counter
    vllm:spec_decode_num_drafts_total{engine="0",model_name="glm-5.3-flash"} 11325.0
    vllm:spec_decode_num_drafts_created{engine="0",model_name="glm-5.3-flash"} 1.7573e+09
    vllm:spec_decode_num_draft_tokens_total{engine="0",model_name="glm-5.3-flash"} 78806.0
    vllm:spec_decode_num_accepted_tokens_total{engine="0",model_name="glm-5.3-flash"} 29746.0
    vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="glm-5.3-flash",position="0"} 8856.0
    vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="glm-5.3-flash",position="1"} 6387.0
    vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="glm-5.3-flash",position="2"} 4677.0
    vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="glm-5.3-flash",position="3"} 3480.0
    vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="glm-5.3-flash",position="4"} 2608.0
    vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="glm-5.3-flash",position="5"} 2073.0
    vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="glm-5.3-flash",position="6"} 1665.0
    """
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

      ctx = context(__MODULE__, deployment: %Deployment{model_name: "qwen3.5-9b"})
      assert {:ok, _} = VLLM.chat(%{"model" => "chat-local", "messages" => []}, ctx)
      assert_received {:request, "/v1/chat/completions", %{"model" => "qwen3.5-9b"}}
    end
  end

  describe "catalog/1" do
    test "uses /v1/models and normalizes served model metadata" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})
        Req.Test.json(conn, models_payload())
      end)

      assert {:ok, [model]} = VLLM.catalog(context(__MODULE__))
      assert model.id == "qwen3.5-9b"
      assert model.root == "QuantTrio/Qwen3.5-9B-AWQ"
      assert model.owned_by == "vllm"
      assert model.context_window == 16_384
      assert model.family == "qwen3.5"
      assert model.parameter_size == "9B"
      assert model.quantization == "AWQ"
      assert_received {:request, "GET", "/v1/models"}
    end
  end

  describe "inspect_model/2" do
    test "finds a served model by id or root" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, models_payload())
      end)

      assert {:ok, metadata} = VLLM.inspect_model("QuantTrio/Qwen3.5-9B-AWQ", context(__MODULE__))
      assert metadata.id == "qwen3.5-9b"
      assert metadata.context_window == 16_384
      assert metadata.root == "QuantTrio/Qwen3.5-9B-AWQ"
    end
  end

  describe "runtime_info/1" do
    test "combines served models with selected Prometheus metrics" do
      Req.Test.stub(__MODULE__, fn
        %{request_path: "/v1/models"} = conn ->
          Req.Test.json(conn, models_payload())

        %{request_path: "/metrics"} = conn ->
          Req.Test.text(conn, metrics_body())
      end)

      assert {:ok, %{running: [running], metrics: %{"qwen3.5-9b" => metrics}}} =
               VLLM.runtime_info(context(__MODULE__))

      assert running.id == "qwen3.5-9b"
      assert metrics["num_requests_running"] == 1.0
      assert metrics["num_requests_waiting"] == 2.0
      assert metrics["kv_cache_usage_perc"] == 0.42
      assert metrics["request_success_total_by_reason"] == %{"stop" => 9.0, "length" => 1.0}
    end

    test "reports the speculative family, with the per-position samples kept apart" do
      Req.Test.stub(__MODULE__, fn
        %{request_path: "/v1/models"} = conn ->
          Req.Test.json(conn, models_payload())

        %{request_path: "/metrics"} = conn ->
          Req.Test.text(conn, speculative_metrics_body())
      end)

      assert {:ok, %{metrics: %{"glm-5.3-flash" => metrics}}} =
               VLLM.runtime_info(context(__MODULE__))

      assert metrics["spec_decode_num_drafts_total"] == 11_325.0
      assert metrics["spec_decode_num_draft_tokens_total"] == 78_806.0
      assert metrics["spec_decode_num_accepted_tokens_total"] == 29_746.0

      assert metrics["spec_decode_accepted_tokens_by_position"] == %{
               0 => 8856.0,
               1 => 6387.0,
               2 => 4677.0,
               3 => 3480.0,
               4 => 2608.0,
               5 => 2073.0,
               6 => 1665.0
             }
    end

    test "keeps no scalar for the per-position family, whose last sample means nothing" do
      Req.Test.stub(__MODULE__, fn
        %{request_path: "/v1/models"} = conn ->
          Req.Test.json(conn, models_payload())

        %{request_path: "/metrics"} = conn ->
          Req.Test.text(conn, speculative_metrics_body())
      end)

      assert {:ok, %{metrics: %{"glm-5.3-flash" => metrics}}} =
               VLLM.runtime_info(context(__MODULE__))

      refute Map.has_key?(metrics, "spec_decode_num_accepted_tokens_per_pos_total")
    end

    test "a slot serving without --speculative-config reports no speculative keys" do
      Req.Test.stub(__MODULE__, fn
        %{request_path: "/v1/models"} = conn ->
          Req.Test.json(conn, models_payload())

        %{request_path: "/metrics"} = conn ->
          Req.Test.text(conn, metrics_body())
      end)

      assert {:ok, %{metrics: %{"qwen3.5-9b" => metrics}}} =
               VLLM.runtime_info(context(__MODULE__))

      assert Enum.all?(Map.keys(metrics), &(not String.starts_with?(&1, "spec_decode")))
    end
  end
end
