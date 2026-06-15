defmodule Airo.RegistryTest do
  use ExUnit.Case, async: true

  alias Airo.Adapters.OpenAICompatible
  alias Airo.Registry

  test "fetch/1 maps OpenAI-compatible types to the shared adapter" do
    for type <- [:openai, :vllm, :ollama, :lmstudio, :speaches] do
      assert Registry.fetch(type) == {:ok, OpenAICompatible}
    end
  end

  test "fetch/1 maps anthropic to its bespoke adapter" do
    assert Registry.fetch(:anthropic) == {:ok, Airo.Adapters.Anthropic}
  end

  test "fetch/1 reports :no_adapter for unimplemented types" do
    assert Registry.fetch(:infinity) == {:error, :no_adapter}
    assert Registry.fetch(:nonsense) == {:error, :no_adapter}
  end

  test "fetch!/1 raises for unimplemented types" do
    assert Registry.fetch!(:vllm) == OpenAICompatible

    assert_raise ArgumentError, ~r/no adapter for :infinity/, fn ->
      Registry.fetch!(:infinity)
    end
  end

  test "every registered adapter type is a known provider adapter_type" do
    valid = Airo.Config.Provider.adapter_types()
    assert Enum.all?(Registry.adapter_types(), &(&1 in valid))
  end
end
