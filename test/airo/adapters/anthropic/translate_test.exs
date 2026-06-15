defmodule Airo.Adapters.Anthropic.TranslateTest do
  use ExUnit.Case, async: true

  alias Airo.Adapters.Anthropic.Translate

  describe "request/2" do
    test "splits system messages out and maps the rest" do
      params = %{
        "messages" => [
          %{"role" => "system", "content" => "be terse"},
          %{"role" => "user", "content" => "hi"}
        ]
      }

      out = Translate.request(params, "claude-x")
      assert out["model"] == "claude-x"
      assert out["system"] == "be terse"
      assert out["messages"] == [%{"role" => "user", "content" => "hi"}]
    end

    test "max_tokens is required: uses request value or defaults" do
      assert Translate.request(%{"messages" => []}, "m")["max_tokens"] == 4096
      assert Translate.request(%{"messages" => [], "max_tokens" => 256}, "m")["max_tokens"] == 256

      assert Translate.request(%{"messages" => [], "max_completion_tokens" => 99}, "m")[
               "max_tokens"
             ] == 99
    end

    test "reasoning_effort maps to a thinking budget" do
      assert Translate.request(%{"messages" => [], "reasoning_effort" => "high"}, "m")["thinking"] ==
               %{"type" => "enabled", "budget_tokens" => 16_384}

      refute Map.has_key?(Translate.request(%{"messages" => []}, "m"), "thinking")
    end

    test "passes temperature/top_p and normalizes stop to stop_sequences" do
      out =
        Translate.request(
          %{"messages" => [], "temperature" => 0.5, "top_p" => 0.9, "stop" => "END"},
          "m"
        )

      assert out["temperature"] == 0.5
      assert out["top_p"] == 0.9
      assert out["stop_sequences"] == ["END"]
    end

    test "translates OpenAI tools to Anthropic tools" do
      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "get_weather",
            "description" => "w",
            "parameters" => %{"type" => "object"}
          }
        }
      ]

      assert Translate.request(%{"messages" => [], "tools" => tools}, "m")["tools"] ==
               [
                 %{
                   "name" => "get_weather",
                   "description" => "w",
                   "input_schema" => %{"type" => "object"}
                 }
               ]
    end
  end

  describe "response/1" do
    test "maps text content, stop_reason, and usage" do
      anthropic = %{
        "id" => "msg_1",
        "model" => "claude-x",
        "content" => [%{"type" => "text", "text" => "hello"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 5}
      }

      out = Translate.response(anthropic)
      assert out["object"] == "chat.completion"
      assert out["id"] == "msg_1"
      choice = hd(out["choices"])
      assert choice["message"]["content"] == "hello"
      assert choice["finish_reason"] == "stop"

      assert out["usage"] == %{
               "prompt_tokens" => 3,
               "completion_tokens" => 5,
               "total_tokens" => 8
             }
    end

    test "thinking → reasoning_content and tool_use → tool_calls with length finish" do
      anthropic = %{
        "id" => "msg_2",
        "model" => "claude-x",
        "content" => [
          %{"type" => "thinking", "thinking" => "hmm"},
          %{"type" => "tool_use", "id" => "tu_1", "name" => "lookup", "input" => %{"q" => "x"}}
        ],
        "stop_reason" => "tool_use",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

      message = Translate.response(anthropic)["choices"] |> hd() |> Map.get("message")
      assert message["reasoning_content"] == "hmm"
      assert [tool] = message["tool_calls"]
      assert tool["function"]["name"] == "lookup"
      assert Jason.decode!(tool["function"]["arguments"]) == %{"q" => "x"}

      assert Translate.response(anthropic)["choices"] |> hd() |> Map.get("finish_reason") ==
               "tool_calls"
    end
  end

  describe "stream_event/1" do
    test "message_start opens with an assistant role delta" do
      assert [chunk] =
               Translate.stream_event(%{"type" => "message_start", "message" => %{"id" => "m"}})

      assert chunk["object"] == "chat.completion.chunk"
      assert hd(chunk["choices"])["delta"] == %{"role" => "assistant"}
    end

    test "text and thinking deltas map to content / reasoning_content" do
      assert [text] =
               Translate.stream_event(%{
                 "type" => "content_block_delta",
                 "index" => 0,
                 "delta" => %{"type" => "text_delta", "text" => "Hi"}
               })

      assert hd(text["choices"])["delta"] == %{"content" => "Hi"}

      assert [think] =
               Translate.stream_event(%{
                 "type" => "content_block_delta",
                 "index" => 0,
                 "delta" => %{"type" => "thinking_delta", "thinking" => "..."}
               })

      assert hd(think["choices"])["delta"] == %{"reasoning_content" => "..."}
    end

    test "tool_use block start and input_json_delta map to tool_calls" do
      [start] =
        Translate.stream_event(%{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{"type" => "tool_use", "id" => "tu", "name" => "f"}
        })

      assert hd(start["choices"])["delta"]["tool_calls"] |> hd() |> get_in(["function", "name"]) ==
               "f"

      [args] =
        Translate.stream_event(%{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"a\""}
        })

      assert hd(args["choices"])["delta"]["tool_calls"]
             |> hd()
             |> get_in(["function", "arguments"]) == "{\"a\""
    end

    test "message_delta carries the finish_reason; noise events emit nothing" do
      assert [done] =
               Translate.stream_event(%{
                 "type" => "message_delta",
                 "delta" => %{"stop_reason" => "end_turn"}
               })

      assert hd(done["choices"])["finish_reason"] == "stop"

      assert Translate.stream_event(%{"type" => "ping"}) == []
      assert Translate.stream_event(%{"type" => "content_block_stop", "index" => 0}) == []
      assert Translate.stream_event(%{"type" => "message_stop"}) == []
    end
  end
end
