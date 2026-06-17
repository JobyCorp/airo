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
end
