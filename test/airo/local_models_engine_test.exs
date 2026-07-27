defmodule Airo.LocalModelsEngineTest do
  @moduledoc """
  Local-model management resolves on the engine for agent-managed slots (S22).

  `adapter_type` names the wire protocol, and every managed slot is `:openai`,
  so resolving on it alone meant a vLLM slot Airo manages got none of the
  `/metrics` and `max_model_len` reporting an *external* vLLM provider gets —
  same engine, opposite treatment, decided only by who manages it.
  """
  use Airo.DataCase, async: true

  alias Airo.{Config, LocalModels}

  defp agent do
    {:ok, agent} =
      Config.create_agent(%{
        host_id: "h-#{System.unique_integer([:positive])}",
        control_url: "http://h:4400"
      })

    agent
  end

  defp slot(agent, attrs \\ %{}) do
    {:ok, provider} =
      Config.create_provider(
        Map.merge(
          %{
            name: "slot-#{System.unique_integer([:positive])}",
            adapter_type: :openai,
            base_url: "http://h:8081/v1",
            auth_kind: :none,
            agent_id: agent.id
          },
          attrs
        )
      )

    provider
  end

  defp bind(provider, engine) do
    {:ok, model} =
      Config.create_model(%{
        upstream_model_id: "m-#{System.unique_integer([:positive])}",
        display_name: "model",
        engine: engine
      })

    {:ok, _} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "model-#{System.unique_integer([:positive])}",
        capabilities: [:chat],
        model_id: model.id
      })

    provider
  end

  describe "agent-managed slots" do
    test "a vLLM slot gets the vLLM adapter's local management" do
      capabilities = agent() |> slot() |> bind("vllm") |> LocalModels.capabilities()

      assert :catalog in capabilities
      assert :runtime_info in capabilities
      assert :inspect_model in capabilities
    end

    test "a llama.cpp slot reports none, rather than the wrong endpoints" do
      # llama-server exposes no catalog Airo consumes. Pointing it at the vLLM
      # adapter would query /metrics and /v1/models with vLLM's expectations.
      assert agent() |> slot() |> bind("llama_cpp") |> LocalModels.capabilities() == []
    end

    test "a slot with nothing bound yet falls back to its adapter_type" do
      # No deployment ⇒ no engine to resolve on. `:openai` implements no
      # LocalProvider, which is the pre-S22 behaviour.
      assert agent() |> slot() |> LocalModels.capabilities() == []
    end

    test "a model with no engine recorded falls back too" do
      assert agent() |> slot() |> bind(nil) |> LocalModels.capabilities() == []
    end
  end

  describe "external providers" do
    test "still resolve on adapter_type, which identifies their backend" do
      {:ok, external} =
        Config.create_provider(%{
          name: "ext-#{System.unique_integer([:positive])}",
          adapter_type: :vllm,
          base_url: "http://ext:8000/v1",
          auth_kind: :none
        })

      capabilities = LocalModels.capabilities(external)

      assert :catalog in capabilities
      assert :runtime_info in capabilities
    end

    test "an unsaved provider struct is still answerable" do
      # `capabilities/1` is called from the shelf and the provider UI with
      # whatever provider is to hand; it must not require a preload.
      assert LocalModels.capabilities(%Config.Provider{adapter_type: :vllm}) != []
      assert LocalModels.capabilities(%Config.Provider{adapter_type: :openai}) == []
    end
  end
end
