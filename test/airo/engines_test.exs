defmodule Airo.EnginesTest do
  @moduledoc """
  The engine differences Airo used to paper over (S22).

  Every agent-managed slot is `adapter_type: :openai` — that names the wire
  protocol — so before this module nothing downstream could tell a llama.cpp
  slot from a vLLM one, and llama.cpp's assumptions were applied to both.
  """
  use ExUnit.Case, async: true

  alias Airo.Engines

  describe "ctx_total/3" do
    test "llama.cpp's KV budget is ctx x parallel" do
      # Contract A: `ctx` is the per-request window and the engine is launched
      # with `-c = ctx x parallel`, so VRAM scales with the product.
      assert Engines.ctx_total("llama_cpp", 36_608, 4) == 146_432
    end

    test "vLLM's is the per-request window alone" do
      # `--max-model-len` IS the window; `parallel` becomes `--max-num-seqs` and
      # the KV pool is sized by gpu-memory-utilization, not by ctx x seqs.
      assert Engines.ctx_total("vllm", 1_048_576, 6) == 1_048_576
    end

    test "the vLLM case is the one that was silently wrong" do
      # This is sparky's DeepSeek. Multiplying by --max-num-seqs over-states the
      # budget 6x, which projected 410 GB against a 118 GB budget and would have
      # hard-blocked a load that is currently running.
      refute Engines.ctx_total("vllm", 1_048_576, 6) == 1_048_576 * 6
    end

    test "an unknown engine keeps llama.cpp's behaviour" do
      # Airo assumed the product everywhere before this existed; an unrecognised
      # engine must not silently change how a slot is validated.
      assert Engines.ctx_total(nil, 36_608, 4) == 146_432
      assert Engines.ctx_total("tgi", 36_608, 4) == 146_432
    end

    test "no context means no budget, whatever the engine" do
      for engine <- ["llama_cpp", "vllm", nil] do
        assert Engines.ctx_total(engine, nil, 4) == nil
      end
    end

    test "a missing parallel counts as one" do
      assert Engines.ctx_total("llama_cpp", 8192, nil) == 8192
    end
  end

  describe "calibratable?/1" do
    test "vLLM cannot be calibrated per KV token" do
      # It reports no ctx_total to divide by, and pre-allocates its KV pool to a
      # VRAM fraction rather than growing it with the context — so the per-token
      # model doesn't describe it even in principle.
      refute Engines.calibratable?("vllm")
    end

    test "llama.cpp can" do
      assert Engines.calibratable?("llama_cpp")
      assert Engines.calibratable?(nil)
    end
  end

  describe "honors_sampling?/1" do
    test "vLLM maps no sampling knob at launch" do
      refute Engines.honors_sampling?("vllm")
    end

    test "llama-server takes all of them as flags" do
      assert Engines.honors_sampling?("llama_cpp")
    end
  end

  describe "clusterable?/1" do
    test "only vLLM spans hosts" do
      assert Engines.clusterable?("vllm")
      refute Engines.clusterable?("llama_cpp")
      refute Engines.clusterable?(nil)
    end
  end

  describe "local_provider/1" do
    test "a managed vLLM slot resolves to the vLLM adapter" do
      # Resolving on adapter_type alone gave it OpenAICompatible, which
      # implements no LocalProvider — so a managed vLLM slot got none of the
      # /metrics reporting an external :vllm provider gets.
      assert Engines.local_provider("vllm") == Airo.Adapters.VLLM
    end

    test "llama.cpp has none, rather than being pointed at the wrong endpoints" do
      assert Engines.local_provider("llama_cpp") == nil
      assert Engines.local_provider(nil) == nil
    end
  end

  describe "label/1" do
    test "reads as the engine's real name" do
      assert Engines.label("llama_cpp") == "llama.cpp"
      assert Engines.label("vllm") == "vLLM"
      assert Engines.label(nil) == "unknown"
    end
  end
end
