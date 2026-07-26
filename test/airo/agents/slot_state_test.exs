defmodule Airo.Agents.SlotStateTest do
  use ExUnit.Case, async: false

  alias Airo.Agents.SlotState

  setup do
    :ets.delete_all_objects(Airo.Runtime.Store.slots_table())
    :ok
  end

  defp slot_id, do: System.unique_integer([:positive])

  describe "resident_since" do
    test "is stamped when a model becomes resident" do
      id = slot_id()

      %{resident_since: since} = SlotState.put(id, %{resident_model: "qwen.gguf", status: "up"})

      assert %DateTime{} = since
    end

    test "survives a status flip and a heartbeat for the same model" do
      id = slot_id()

      %{resident_since: since} =
        SlotState.put(id, %{resident_model: "qwen.gguf", status: "loading"})

      SlotState.put(id, %{resident_model: "qwen.gguf", status: "up"})

      %{resident_since: after_heartbeat} =
        SlotState.put(id, %{resident_model: "qwen.gguf", status: "up"})

      assert after_heartbeat == since
    end

    test "resets when the slot swaps to a different model" do
      id = slot_id()

      %{resident_since: since} = SlotState.put(id, %{resident_model: "qwen.gguf", status: "up"})
      Process.sleep(1_100)

      %{resident_since: swapped} =
        SlotState.put(id, %{resident_model: "llama.gguf", status: "up"})

      assert DateTime.compare(swapped, since) == :gt
    end

    test "is nil for an empty slot" do
      id = slot_id()

      assert %{resident_since: nil} = SlotState.put(id, %{resident_model: nil, status: "empty"})
    end

    test "restamps when a model is unloaded and the same one is loaded again" do
      id = slot_id()

      %{resident_since: since} = SlotState.put(id, %{resident_model: "qwen.gguf", status: "up"})
      SlotState.put(id, %{resident_model: nil, status: "empty"})
      Process.sleep(1_100)

      %{resident_since: reloaded} =
        SlotState.put(id, %{resident_model: "qwen.gguf", status: "up"})

      assert DateTime.compare(reloaded, since) == :gt
    end
  end

  test "profile is preserved across a push that omits it" do
    id = slot_id()

    SlotState.put(id, %{resident_model: "qwen.gguf", status: "up", profile: %{"kv" => "q8_0"}})
    %{profile: profile} = SlotState.put(id, %{resident_model: "qwen.gguf", status: "down"})

    assert profile == %{"kv" => "q8_0"}
  end
end
