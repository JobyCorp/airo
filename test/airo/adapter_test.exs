defmodule Airo.AdapterTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter
  alias Airo.Adapters.{OpenAICompatible, VLLM}

  test "supports?/2 reflects which callbacks an adapter implements" do
    assert Adapter.supports?(OpenAICompatible, :chat)
    assert Adapter.supports?(OpenAICompatible, :stream)
    assert Adapter.supports?(OpenAICompatible, :embed)
    # Not yet implemented.
    refute Adapter.supports?(OpenAICompatible, :rerank)
  end

  test "vLLM serves audio (omni builds expose /audio/speech + /audio/transcriptions)" do
    assert Adapter.supports?(VLLM, :speech)
    assert Adapter.supports?(VLLM, :transcribe)
    assert Adapter.supports?(VLLM, :chat)
  end

  test "speech adapters expose voice discovery (voices/1)" do
    for mod <- [VLLM, Airo.Adapters.Speaches, OpenAICompatible] do
      assert Code.ensure_loaded?(mod) and function_exported?(mod, :voices, 1)
    end
  end

  test "capabilities/0 lists the contract callbacks" do
    assert :chat in Adapter.capabilities()
    assert :stream in Adapter.capabilities()
  end
end
