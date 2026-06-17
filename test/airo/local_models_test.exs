defmodule Airo.LocalModelsTest do
  use Airo.DataCase, async: true

  alias Airo.{Config, LocalModels}

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
end
