defmodule Airo.Adapters.Anthropic.Translate do
  @moduledoc """
  Pure translation between the OpenAI chat shape (Airo's canonical wire) and the
  Anthropic Messages API (DESIGN §6). All normalization lives here so the adapter
  stays thin and this can be exhaustively unit-tested.

    - `request/2` — OpenAI `/chat/completions` body → Anthropic `/v1/messages` body
      (system split out, required `max_tokens`, `reasoning_effort` → `thinking`,
      tools, stop sequences).
    - `response/1` — Anthropic message → OpenAI completion (text, `thinking` →
      `reasoning_content`, `tool_use` → `tool_calls`, stop-reason mapping, usage).
    - `stream_event/1` — one Anthropic SSE event → zero or more OpenAI delta
      chunks (dispatched on the event's `"type"`, so the raw `event:` line is not
      needed).
  """

  @default_max_tokens 4096
  @anthropic_version "2023-06-01"

  # reasoning_effort → Anthropic thinking budget_tokens
  @thinking_budgets %{"low" => 1024, "medium" => 4096, "high" => 16_384}

  def anthropic_version, do: @anthropic_version

  ## Request

  @spec request(map(), String.t()) :: map()
  def request(params, model) when is_map(params) do
    {system, messages} = split_system(Map.get(params, "messages", []))

    %{
      "model" => model,
      "max_tokens" =>
        params["max_tokens"] || params["max_completion_tokens"] || @default_max_tokens,
      "messages" => Enum.map(messages, &message/1)
    }
    |> put_present("system", system)
    |> put_present("temperature", params["temperature"])
    |> put_present("top_p", params["top_p"])
    |> put_present("stop_sequences", stop_sequences(params["stop"]))
    |> put_thinking(params["reasoning_effort"])
    |> put_tools(params["tools"])
  end

  defp split_system(messages) do
    {system, rest} = Enum.split_with(messages, &(&1["role"] == "system"))
    text = system |> Enum.map(&content_text(&1["content"])) |> Enum.join("\n")
    {if(text == "", do: nil, else: text), rest}
  end

  defp message(%{"role" => role, "content" => content}),
    do: %{"role" => role, "content" => content_text(content)}

  # Anthropic accepts a string or content blocks; we send the flattened text.
  defp content_text(content) when is_binary(content), do: content

  defp content_text(parts) when is_list(parts),
    do: parts |> Enum.map(fn p -> p["text"] || "" end) |> Enum.join()

  defp content_text(_), do: ""

  defp stop_sequences(nil), do: nil
  defp stop_sequences(stop) when is_binary(stop), do: [stop]
  defp stop_sequences(stop) when is_list(stop), do: stop

  defp put_thinking(body, effort) when is_binary(effort) do
    case Map.fetch(@thinking_budgets, effort) do
      {:ok, budget} ->
        Map.put(body, "thinking", %{"type" => "enabled", "budget_tokens" => budget})

      :error ->
        body
    end
  end

  defp put_thinking(body, _), do: body

  defp put_tools(body, tools) when is_list(tools) and tools != [] do
    Map.put(body, "tools", Enum.map(tools, &tool/1))
  end

  defp put_tools(body, _), do: body

  defp tool(%{"function" => fun}) do
    %{
      "name" => fun["name"],
      "description" => fun["description"],
      "input_schema" => fun["parameters"]
    }
    |> reject_nil()
  end

  ## Response

  @spec response(map()) :: map()
  def response(%{"content" => blocks} = message) do
    text = blocks |> typed("text") |> Enum.map_join(& &1["text"])
    thinking = blocks |> typed("thinking") |> Enum.map_join(& &1["thinking"])
    tool_calls = blocks |> typed("tool_use") |> Enum.with_index() |> Enum.map(&tool_call/1)

    inner =
      %{"role" => "assistant", "content" => text}
      |> put_present("reasoning_content", nilify(thinking))
      |> put_present("tool_calls", nilify_list(tool_calls))

    %{
      "id" => message["id"],
      "object" => "chat.completion",
      "model" => message["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => inner,
          "finish_reason" => finish_reason(message["stop_reason"])
        }
      ],
      "usage" => usage(message["usage"])
    }
  end

  defp tool_call({%{"id" => id, "name" => name, "input" => input}, index}) do
    %{
      "index" => index,
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(input)}
    }
  end

  defp usage(%{"input_tokens" => input, "output_tokens" => output}) do
    %{"prompt_tokens" => input, "completion_tokens" => output, "total_tokens" => input + output}
  end

  defp usage(_), do: nil

  defp finish_reason("end_turn"), do: "stop"
  defp finish_reason("stop_sequence"), do: "stop"
  defp finish_reason("max_tokens"), do: "length"
  defp finish_reason("tool_use"), do: "tool_calls"
  defp finish_reason(_), do: nil

  ## Streaming

  @spec stream_event(map()) :: [map()]
  def stream_event(%{"type" => "message_start"}), do: [chunk(%{"role" => "assistant"})]

  def stream_event(%{
        "type" => "content_block_start",
        "index" => index,
        "content_block" => %{"type" => "tool_use"} = block
      }) do
    [
      chunk(%{
        "tool_calls" => [
          %{
            "index" => index,
            "id" => block["id"],
            "type" => "function",
            "function" => %{"name" => block["name"], "arguments" => ""}
          }
        ]
      })
    ]
  end

  def stream_event(%{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => text}
      }),
      do: [chunk(%{"content" => text})]

  def stream_event(%{
        "type" => "content_block_delta",
        "delta" => %{"type" => "thinking_delta", "thinking" => thinking}
      }),
      do: [chunk(%{"reasoning_content" => thinking})]

  def stream_event(%{
        "type" => "content_block_delta",
        "index" => index,
        "delta" => %{"type" => "input_json_delta", "partial_json" => json}
      }),
      do: [chunk(%{"tool_calls" => [%{"index" => index, "function" => %{"arguments" => json}}]})]

  def stream_event(%{"type" => "message_delta", "delta" => %{"stop_reason" => reason}})
      when not is_nil(reason),
      do: [chunk(%{}, finish_reason(reason))]

  # ping, content_block_stop, message_stop, and anything unrecognized → nothing.
  def stream_event(_event), do: []

  defp chunk(delta, finish_reason \\ nil) do
    %{
      "object" => "chat.completion.chunk",
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }
  end

  ## Helpers

  defp typed(blocks, type), do: Enum.filter(blocks, &(&1["type"] == type))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp nilify(""), do: nil
  defp nilify(value), do: value

  defp nilify_list([]), do: nil
  defp nilify_list(list), do: list

  defp reject_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
