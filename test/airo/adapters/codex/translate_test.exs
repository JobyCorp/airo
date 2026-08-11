defmodule Airo.Adapters.Codex.TranslateTest do
  use ExUnit.Case, async: true

  alias Airo.Adapters.Codex.Translate

  describe "request/2" do
    test "maps system to instructions and messages to input items" do
      body =
        Translate.request(
          %{
            "messages" => [
              %{"role" => "system", "content" => "be terse"},
              %{"role" => "user", "content" => "yo"},
              %{"role" => "assistant", "content" => "hi"}
            ],
            "max_tokens" => 256,
            "temperature" => 0.2
          },
          "gpt-5.1-codex"
        )

      assert body["model"] == "gpt-5.1-codex"
      assert body["instructions"] == "be terse"
      assert body["store"] == false

      assert body["input"] == [
               %{
                 "type" => "message",
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => "yo"}]
               },
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "hi"}]
               }
             ]
    end

    test "maps tool traffic to function_call / function_call_output items" do
      body =
        Translate.request(
          %{
            "messages" => [
              %{"role" => "user", "content" => "weather?"},
              %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"SF"})}
                  }
                ]
              },
              %{"role" => "tool", "tool_call_id" => "call_1", "content" => "sunny"}
            ]
          },
          "gpt-5.1-codex"
        )

      assert [
               %{"type" => "message", "role" => "user"},
               %{
                 "type" => "function_call",
                 "call_id" => "call_1",
                 "name" => "get_weather",
                 "arguments" => ~s({"city":"SF"})
               },
               %{"type" => "function_call_output", "call_id" => "call_1", "output" => "sunny"}
             ] = body["input"]
    end

    test "flattens tool definitions and maps a forced tool_choice" do
      body =
        Translate.request(
          %{
            "messages" => [],
            "tools" => [
              %{
                "type" => "function",
                "function" => %{
                  "name" => "get_weather",
                  "description" => "weather",
                  "parameters" => %{"type" => "object"}
                }
              }
            ],
            "tool_choice" => %{"type" => "function", "function" => %{"name" => "get_weather"}}
          },
          "gpt-5.1-codex"
        )

      assert body["tools"] == [
               %{
                 "type" => "function",
                 "name" => "get_weather",
                 "description" => "weather",
                 "parameters" => %{"type" => "object"},
                 "strict" => false
               }
             ]

      assert body["tool_choice"] == %{"type" => "function", "name" => "get_weather"}
    end

    test "drops sampling and cap params the subscription backend rejects" do
      body =
        Translate.request(
          %{
            "messages" => [],
            "max_tokens" => 256,
            "max_completion_tokens" => 256,
            "temperature" => 0.2,
            "top_p" => 0.9
          },
          "gpt-5.4-mini"
        )

      for key <- ["max_output_tokens", "max_tokens", "temperature", "top_p"] do
        refute Map.has_key?(body, key), "expected #{key} to be dropped"
      end
    end

    test "maps reasoning_effort to reasoning with an auto summary" do
      body = Translate.request(%{"messages" => [], "reasoning_effort" => "high"}, "gpt-5.1")
      assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}

      refute Translate.request(%{"messages" => []}, "gpt-5.1") |> Map.has_key?("reasoning")
    end
  end

  describe "response/1" do
    test "maps output items to an OpenAI completion" do
      openai =
        Translate.response(%{
          "id" => "resp_1",
          "model" => "gpt-5.1-codex",
          "status" => "completed",
          "output" => [
            %{
              "type" => "reasoning",
              "summary" => [%{"type" => "summary_text", "text" => "mull"}]
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "hi there"}]
            }
          ],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
        })

      assert %{
               "id" => "resp_1",
               "object" => "chat.completion",
               "model" => "gpt-5.1-codex",
               "choices" => [choice],
               "usage" => %{
                 "prompt_tokens" => 4,
                 "completion_tokens" => 2,
                 "total_tokens" => 6
               }
             } = openai

      assert choice["finish_reason"] == "stop"
      assert choice["message"]["content"] == "hi there"
      assert choice["message"]["reasoning_content"] == "mull"
      refute Map.has_key?(choice["message"], "tool_calls")
    end

    test "maps function_call items to tool_calls with a tool_calls finish" do
      openai =
        Translate.response(%{
          "id" => "resp_2",
          "status" => "completed",
          "output" => [
            %{
              "type" => "function_call",
              "call_id" => "call_1",
              "name" => "get_weather",
              "arguments" => ~s({"city":"SF"})
            }
          ]
        })

      assert [choice] = openai["choices"]
      assert choice["finish_reason"] == "tool_calls"

      assert choice["message"]["tool_calls"] == [
               %{
                 "index" => 0,
                 "id" => "call_1",
                 "type" => "function",
                 "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"SF"})}
               }
             ]
    end

    test "maps an incomplete status to a length finish" do
      openai = Translate.response(%{"id" => "resp_3", "status" => "incomplete", "output" => []})
      assert [%{"finish_reason" => "length"}] = openai["choices"]
    end
  end

  describe "stream_event/1" do
    test "response.created opens the assistant role" do
      assert [%{"choices" => [%{"delta" => %{"role" => "assistant"}}]}] =
               Translate.stream_event(%{"type" => "response.created"})
    end

    test "output_text and reasoning deltas become content chunks" do
      assert [%{"choices" => [%{"delta" => %{"content" => "He"}}]}] =
               Translate.stream_event(%{"type" => "response.output_text.delta", "delta" => "He"})

      assert [%{"choices" => [%{"delta" => %{"reasoning_content" => "hm"}}]}] =
               Translate.stream_event(%{
                 "type" => "response.reasoning_summary_text.delta",
                 "delta" => "hm"
               })
    end

    test "function_call item + argument deltas become tool_call chunks" do
      assert [%{"choices" => [%{"delta" => %{"tool_calls" => [open]}}]}] =
               Translate.stream_event(%{
                 "type" => "response.output_item.added",
                 "output_index" => 1,
                 "item" => %{"type" => "function_call", "call_id" => "call_1", "name" => "f"}
               })

      assert open == %{
               "index" => 1,
               "id" => "call_1",
               "type" => "function",
               "function" => %{"name" => "f", "arguments" => ""}
             }

      assert [%{"choices" => [%{"delta" => %{"tool_calls" => [delta]}}]}] =
               Translate.stream_event(%{
                 "type" => "response.function_call_arguments.delta",
                 "output_index" => 1,
                 "delta" => ~s({"ci)
               })

      assert delta == %{"index" => 1, "function" => %{"arguments" => ~s({"ci)}}
    end

    test "response.completed carries the finish reason and usage" do
      assert [chunk] =
               Translate.stream_event(%{
                 "type" => "response.completed",
                 "response" => %{
                   "output" => [%{"type" => "message"}],
                   "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
                 }
               })

      assert [%{"finish_reason" => "stop"}] = chunk["choices"]
      assert chunk["usage"]["total_tokens"] == 6

      assert [%{"choices" => [%{"finish_reason" => "tool_calls"}]}] =
               Translate.stream_event(%{
                 "type" => "response.completed",
                 "response" => %{"output" => [%{"type" => "function_call"}]}
               })
    end

    test "bookkeeping events yield nothing" do
      assert Translate.stream_event(%{"type" => "response.in_progress"}) == []
      assert Translate.stream_event(%{"type" => "response.output_text.done"}) == []
      assert Translate.stream_event(%{"type" => "something.new"}) == []
    end
  end
end
