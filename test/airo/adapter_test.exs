defmodule Airo.AdapterTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter
  alias Airo.Adapters.OpenAICompatible

  test "supports?/2 reflects which callbacks an adapter implements" do
    assert Adapter.supports?(OpenAICompatible, :chat)
    assert Adapter.supports?(OpenAICompatible, :stream)
    # Not yet implemented.
    refute Adapter.supports?(OpenAICompatible, :embed)
  end

  test "capabilities/0 lists the contract callbacks" do
    assert :chat in Adapter.capabilities()
    assert :stream in Adapter.capabilities()
  end
end
