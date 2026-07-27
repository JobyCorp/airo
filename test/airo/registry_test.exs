defmodule Airo.RegistryTest do
  use ExUnit.Case, async: true

  alias Airo.Adapters.{LMStudio, Ollama, OpenAICompatible, Speaches, Unsloth, VLLM}
  alias Airo.Registry

  # The moduledoc examples had drifted from the map (`:vllm` was documented as
  # OpenAICompatible, `:anthropic` as unregistered). This is the module a reader
  # consults to answer "what handles vLLM?", so pin the docs to the behaviour.
  doctest Airo.Registry

  test "fetch/1 maps OpenAI-compatible types to the shared adapter" do
    for type <- [:openai] do
      assert Registry.fetch(type) == {:ok, OpenAICompatible}
    end
  end

  test "fetch/1 maps the bespoke adapters" do
    assert Registry.fetch(:vllm) == {:ok, VLLM}
    assert Registry.fetch(:ollama) == {:ok, Ollama}
    assert Registry.fetch(:lmstudio) == {:ok, LMStudio}
    assert Registry.fetch(:speaches) == {:ok, Speaches}
    assert Registry.fetch(:unsloth) == {:ok, Unsloth}
    assert Registry.fetch(:anthropic) == {:ok, Airo.Adapters.Anthropic}
    assert Registry.fetch(:infinity) == {:ok, Airo.Adapters.Infinity}
  end

  test "fetch/1 reports :no_adapter for unknown types" do
    assert Registry.fetch(:nonsense) == {:error, :no_adapter}
  end

  test "fetch!/1 raises for unknown types" do
    assert Registry.fetch!(:vllm) == VLLM

    assert_raise ArgumentError, ~r/no adapter for :nonsense/, fn ->
      Registry.fetch!(:nonsense)
    end
  end

  test "every registered adapter type is a known provider adapter_type" do
    valid = Airo.Config.Provider.adapter_types()
    assert Enum.all?(Registry.adapter_types(), &(&1 in valid))
  end
end
