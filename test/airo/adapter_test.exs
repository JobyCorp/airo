defmodule Airo.AdapterTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter
  alias Airo.Adapters.OpenAICompatible

  test "supports?/2 reflects which callbacks an adapter implements" do
    assert Adapter.supports?(OpenAICompatible, :chat)
    assert Adapter.supports?(OpenAICompatible, :stream)
    assert Adapter.supports?(OpenAICompatible, :embed)
    # Not yet implemented.
    refute Adapter.supports?(OpenAICompatible, :rerank)
  end

  test "capabilities/0 lists the contract callbacks" do
    assert :chat in Adapter.capabilities()
    assert :stream in Adapter.capabilities()
  end
end
