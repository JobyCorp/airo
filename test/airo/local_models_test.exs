defmodule Airo.LocalModelsTest do
  use Airo.DataCase, async: true

  alias Airo.{Config, LocalModels}

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

  defp stub_lmstudio_native do
    Req.Test.stub(Airo.TestStub, fn
      %{request_path: "/api/v1/models"} = conn ->
        Req.Test.json(conn, %{
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
                  "config" => %{"context_length" => 4096}
                }
              ],
              "max_context_length" => 262_144,
              "format" => "gguf",
              "capabilities" => %{"vision" => true, "trained_for_tool_use" => true},
              "variants" => ["google/gemma-4-26b-a4b@q4_k_m"],
              "selected_variant" => "google/gemma-4-26b-a4b@q4_k_m"
            }
          ]
        })
    end)
  end

  defp stub_vllm_native do
    Req.Test.stub(Airo.TestStub, fn
      %{request_path: "/v1/models"} = conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "qwen3.5-9b",
              "created" => 1_781_702_879,
              "owned_by" => "vllm",
              "root" => "QuantTrio/Qwen3.5-9B-AWQ",
              "max_model_len" => 16_384,
              "permission" => [%{"allow_sampling" => true}]
            }
          ]
        })

      %{request_path: "/metrics"} = conn ->
        Req.Test.text(
          conn,
          """
          vllm:num_requests_running{engine="0",model_name="qwen3.5-9b"} 0.0
          vllm:num_requests_waiting{engine="0",model_name="qwen3.5-9b"} 1.0
          vllm:kv_cache_usage_perc{engine="0",model_name="qwen3.5-9b"} 0.12
          vllm:prompt_tokens_total{engine="0",model_name="qwen3.5-9b"} 1000.0
          vllm:generation_tokens_total{engine="0",model_name="qwen3.5-9b"} 500.0
          vllm:request_success_total{engine="0",finished_reason="stop",model_name="qwen3.5-9b"} 8.0
          """
        )
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
          ]
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

  defp stub_speaches_native do
    Req.Test.stub(Airo.TestStub, fn
      %{request_path: "/v1/models/speaches-ai%2FKokoro-82M-v1.0-ONNX"} = conn ->
        Req.Test.json(conn, %{
          "id" => "speaches-ai/Kokoro-82M-v1.0-ONNX",
          "created" => 1_778_979_749,
          "object" => "model",
          "owned_by" => "speaches-ai",
          "language" => ["multilingual"],
          "task" => "text-to-speech",
          "sample_rate" => 24_000,
          "voices" => [
            %{"name" => "af_heart", "language" => "en-us", "gender" => "female"},
            %{"name" => "am_echo", "language" => "en-us", "gender" => "male"},
            %{"name" => "jf_alpha", "language" => "ja", "gender" => "female"}
          ]
        })

      %{request_path: "/api/ps"} = conn ->
        Req.Test.json(conn, %{"models" => ["speaches-ai/Kokoro-82M-v1.0-ONNX"]})
    end)
  end

  test "reports local management capabilities for Ollama providers" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "ollama-mini",
        adapter_type: :ollama,
        base_url: "http://ollama:11434/v1",
        auth_kind: :none
      })

    assert LocalModels.capabilities(provider) == [
             :catalog,
             :inspect_model,
             :pull_model,
             :runtime_info
           ]
  end

  test "reports local management capabilities for LM Studio providers" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "lmstudio-mini",
        adapter_type: :lmstudio,
        base_url: "http://lmstudio:1234/v1",
        auth_kind: :none
      })

    assert LocalModels.capabilities(provider) == [
             :catalog,
             :inspect_model,
             :pull_model,
             :runtime_info
           ]
  end

  test "reports read-only local management capabilities for vLLM providers" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "vllm-mini",
        adapter_type: :vllm,
        base_url: "http://vllm:8000/v1",
        auth_kind: :none
      })

    assert LocalModels.capabilities(provider) == [
             :catalog,
             :inspect_model,
             :runtime_info
           ]
  end

  test "reports read-only local management capabilities for Infinity providers" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "infinity-mini",
        adapter_type: :infinity,
        base_url: "http://infinity:7997",
        auth_kind: :none
      })

    assert LocalModels.capabilities(provider) == [
             :catalog,
             :inspect_model,
             :runtime_info
           ]
  end

  test "reports read-only local management capabilities for Speaches providers" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "speaches-mini",
        adapter_type: :speaches,
        base_url: "http://speaches:8000/v1",
        auth_kind: :none
      })

    assert LocalModels.capabilities(provider) == [
             :catalog,
             :inspect_model,
             :runtime_info
           ]
  end

  test "reports no local management capabilities for remote providers" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "openai",
        adapter_type: :openai,
        base_url: "https://api.openai.com/v1",
        auth_kind: :api_key
      })

    assert LocalModels.capabilities(provider) == []
    assert {:error, :unsupported} = LocalModels.catalog(provider)
  end

  test "sync_deployment/1 stores provider metadata and updates model fields" do
    stub_ollama_native()

    {:ok, provider} =
      Config.create_provider(%{
        name: "ollama-mini",
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

    assert {:ok, synced} = LocalModels.sync_deployment(deployment)

    assert synced.provider_metadata["family"] == "moondream"
    assert synced.provider_metadata["quantization"] == "Q4_K_M"
    assert synced.provider_metadata["parameter_size"] == "1.6B"
    assert synced.provider_metadata["runtime_version"] == "0.5.1"
    assert synced.provider_metadata["running"] == true
    assert synced.provider_metadata["modelfile"] == "FROM moondream:latest"

    model = Config.get_model!(deployment.model_id)
    assert model.family == "moondream"
    assert model.quantization == "Q4_K_M"
    assert model.size == "1.6B"
  end

  test "reports lifecycle + read management capabilities for airo_agent providers" do
    {:ok, provider} =
      Config.create_provider(%{
        name: "jobycorp-caps",
        adapter_type: :airo_agent,
        base_url: "http://agent:4400",
        auth_kind: :none
      })

    # Lifecycle-owned: load/unload, but no pull (acquisition is out of band).
    assert LocalModels.capabilities(provider) == [
             :catalog,
             :inspect_model,
             :runtime_info,
             :load_model,
             :unload_model
           ]
  end

  test "sync_deployment/1 fills the shelf REVISION from the agent's provenance" do
    Req.Test.stub(Airo.TestStub, fn
      %{request_path: "/inventory"} = conn ->
        Req.Test.json(conn, %{
          "models" => [
            %{
              "id" => "org/repo:Q4",
              "repo" => "org/repo",
              "revision" => "907becb33103",
              "quant" => "UD-Q4_K_XL",
              "family" => "qwen3",
              "ctx_max" => 8192,
              "engine" => "llama_cpp",
              "capabilities" => ["chat"]
            }
          ]
        })

      %{request_path: "/running"} = conn ->
        Req.Test.json(conn, %{"instances" => []})

      %{request_path: "/gpu"} = conn ->
        Req.Test.json(conn, %{"available" => true})
    end)

    {:ok, provider} =
      Config.create_provider(%{
        name: "jobycorp-sync",
        adapter_type: :airo_agent,
        base_url: "http://agent:4400",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "org/repo:Q4",
        capabilities: [:chat]
      })

    assert {:ok, _synced} = LocalModels.sync_deployment(deployment)

    model = Config.get_model!(deployment.model_id)
    # The payoff Ollama/LM Studio can't give: the HF snapshot sha on the shelf.
    assert model.revision == "907becb33103"
    assert model.quantization == "UD-Q4_K_XL"
    assert model.family == "qwen3"
  end

  test "sync_deployment/1 stores LM Studio metadata from the native catalog" do
    stub_lmstudio_native()

    {:ok, provider} =
      Config.create_provider(%{
        name: "lmstudio-mini",
        adapter_type: :lmstudio,
        base_url: "http://lmstudio:1234/v1",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "google/gemma-4-26b-a4b@q4_k_m",
        capabilities: [:chat, :vision]
      })

    assert {:ok, synced} = LocalModels.sync_deployment(deployment)

    assert synced.provider_metadata["provider_type"] == "lmstudio"
    assert synced.provider_metadata["publisher"] == "google"
    assert synced.provider_metadata["family"] == "gemma4"
    assert synced.provider_metadata["quantization"] == "Q4_K_M"
    assert synced.provider_metadata["parameter_size"] == "26B-A4B"
    assert synced.provider_metadata["context_window"] == 4096
    assert synced.provider_metadata["max_context_window"] == 262_144
    assert synced.provider_metadata["running"] == true
    assert synced.provider_metadata["vision"] == true
    assert synced.provider_metadata["trained_for_tool_use"] == true

    model = Config.get_model!(deployment.model_id)
    assert model.family == "gemma4"
    assert model.quantization == "Q4_K_M"
    assert model.size == "26B-A4B"
  end

  test "sync_deployment/1 stores vLLM served model metadata and runtime metrics" do
    stub_vllm_native()

    {:ok, provider} =
      Config.create_provider(%{
        name: "vllm-mini",
        adapter_type: :vllm,
        base_url: "http://vllm:8000/v1",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "qwen3.5-9b",
        capabilities: [:chat]
      })

    assert {:ok, synced} = LocalModels.sync_deployment(deployment)

    assert synced.provider_metadata["provider_type"] == "vllm"
    assert synced.provider_metadata["root"] == "QuantTrio/Qwen3.5-9B-AWQ"
    assert synced.provider_metadata["owned_by"] == "vllm"
    assert synced.provider_metadata["family"] == "qwen3.5"
    assert synced.provider_metadata["parameter_size"] == "9B"
    assert synced.provider_metadata["quantization"] == "AWQ"
    assert synced.provider_metadata["context_window"] == 16_384
    assert synced.provider_metadata["running"] == true
    assert synced.provider_metadata["metrics"]["kv_cache_usage_perc"] == 0.12

    assert synced.provider_metadata["metrics"]["request_success_total_by_reason"] == %{
             "stop" => 8.0
           }

    model = Config.get_model!(deployment.model_id)
    assert model.family == "qwen3.5"
    assert model.quantization == "AWQ"
    assert model.size == "9B"
  end

  test "sync_deployment/1 stores Infinity model metadata and endpoint metrics" do
    stub_infinity_native()

    {:ok, provider} =
      Config.create_provider(%{
        name: "infinity-mini",
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

    assert {:ok, synced} = LocalModels.sync_deployment(deployment)

    assert synced.provider_metadata["provider_type"] == "infinity"
    assert synced.provider_metadata["family"] == "bge"
    assert synced.provider_metadata["type"] == "rerank"
    assert synced.provider_metadata["backend"] == "torch"
    assert synced.provider_metadata["owned_by"] == "infinity"
    assert synced.provider_metadata["running"] == true
    assert synced.provider_metadata["batch_size"] == 32
    assert synced.provider_metadata["queue_absolute"] == 0
    assert synced.provider_metadata["metrics"]["requests_post_2xx"] == 250.0
    assert synced.provider_metadata["metrics"]["duration_post_count"] == 250.0

    model = Config.get_model!(deployment.model_id)
    assert model.family == "bge"
  end

  test "sync_deployment/1 stores Speaches audio model metadata" do
    stub_speaches_native()

    {:ok, provider} =
      Config.create_provider(%{
        name: "speaches-mini",
        adapter_type: :speaches,
        base_url: "http://speaches:8000/v1",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "speaches-ai/Kokoro-82M-v1.0-ONNX",
        capabilities: [:speech]
      })

    assert {:ok, synced} = LocalModels.sync_deployment(deployment)

    assert synced.provider_metadata["provider_type"] == "speaches"
    assert synced.provider_metadata["type"] == "speech"
    assert synced.provider_metadata["task"] == "text-to-speech"
    assert synced.provider_metadata["owned_by"] == "speaches-ai"
    assert synced.provider_metadata["family"] == "kokoro"
    assert synced.provider_metadata["sample_rate"] == 24_000
    assert synced.provider_metadata["language_count"] == 1
    assert synced.provider_metadata["voice_count"] == 3
    assert synced.provider_metadata["voice_languages"] == ["en-us", "ja"]
    assert synced.provider_metadata["running"] == true

    model = Config.get_model!(deployment.model_id)
    assert model.family == "kokoro"
  end
end
