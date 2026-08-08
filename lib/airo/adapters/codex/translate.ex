defmodule Airo.Adapters.Codex.Translate do
  @moduledoc """
  Pure translation between the OpenAI chat shape (Airo's canonical wire) and
  the Responses API the ChatGPT Codex backend speaks (DESIGN §6). Mirrors
  `Airo.Adapters.Anthropic.Translate` so the adapter stays thin and this can be
  exhaustively unit-tested.

    - `request/2` — OpenAI `/chat/completions` body → `/responses` body
      (system/developer → `instructions`, messages and tool traffic → `input`
      items, tools flattened, `reasoning_effort` → `reasoning.effort`; always
      `store: false`, the backend keeps no state for us). Sampling and cap
      params (`max_tokens`, `temperature`, `top_p`) are dropped — the
      subscription backend 400s on them.
    - `response/1` — a complete Responses object (the terminal
      `response.completed` payload) → OpenAI completion.
    - `stream_event/1` — one Responses SSE event → zero or more OpenAI delta
      chunks (dispatched on the event's `"type"`).
  """

  @efforts ~w(minimal low medium high)

  ## Request

  @spec request(map(), String.t()) :: map()
  def request(params, model) when is_map(params) do
    {instructions, messages} = split_system(Map.get(params, "messages", []))

    # No sampling or cap params: the subscription backend accepts only what the
    # Codex CLI itself sends and 400s the whole call on `max_output_tokens`,
    # `temperature`, or `top_p` ("Unsupported parameter"). A client-supplied
    # max_tokens cap therefore cannot be enforced upstream and is dropped, like
    # every other param this backend rejects.
    %{
      "model" => model,
      "input" => Enum.flat_map(messages, &items/1),
      "store" => false
    }
    |> put_present("instructions", instructions)
    |> put_present("tool_choice", tool_choice(params["tool_choice"]))
    |> put_reasoning(params["reasoning_effort"])
    |> put_tools(params["tools"])
  end

  defp split_system(messages) do
    {system, rest} = Enum.split_with(messages, &(&1["role"] in ["system", "developer"]))
    text = system |> Enum.map(&content_text(&1["content"])) |> Enum.join("\n")
    {if(text == "", do: nil, else: text), rest}
  end

  # One chat message → Responses input items. Tool traffic maps to dedicated
  # item types (`function_call` / `function_call_output`), not message content.
  defp items(%{"role" => "tool"} = msg) do
    [
      %{
        "type" => "function_call_output",
        "call_id" => msg["tool_call_id"],
        "output" => content_text(msg["content"])
      }
    ]
  end

  defp items(%{"role" => "assistant"} = msg) do
    calls =
      for call <- msg["tool_calls"] || [] do
        %{
          "type" => "function_call",
          "call_id" => call["id"],
          "name" => get_in(call, ["function", "name"]),
          "arguments" => get_in(call, ["function", "arguments"]) || ""
        }
      end

    case content_text(msg["content"]) do
      "" -> calls
      text -> [message_item("assistant", "output_text", text) | calls]
    end
  end

  defp items(%{"role" => role} = msg),
    do: [message_item(role, "input_text", content_text(msg["content"]))]

  defp message_item(role, type, text),
    do: %{"type" => "message", "role" => role, "content" => [%{"type" => type, "text" => text}]}

  # Responses accepts typed content parts; we send the flattened text.
  defp content_text(content) when is_binary(content), do: content

  defp content_text(parts) when is_list(parts),
    do: parts |> Enum.map(fn part -> part["text"] || "" end) |> Enum.join()

  defp content_text(_), do: ""

  defp tool_choice(choice) when choice in ["auto", "none", "required"], do: choice

  defp tool_choice(%{"type" => "function", "function" => %{"name" => name}}),
    do: %{"type" => "function", "name" => name}

  defp tool_choice(_), do: nil

  defp put_reasoning(body, effort) when effort in @efforts,
    do: Map.put(body, "reasoning", %{"effort" => effort, "summary" => "auto"})

  defp put_reasoning(body, _), do: body

  defp put_tools(body, tools) when is_list(tools) and tools != [] do
    Map.put(body, "tools", Enum.map(tools, &tool/1))
  end

  defp put_tools(body, _), do: body

  # Responses tool definitions are flat — no `"function"` nesting.
  defp tool(%{"function" => fun}) do
    %{
      "type" => "function",
      "name" => fun["name"],
      "description" => fun["description"],
      "parameters" => fun["parameters"],
      "strict" => false
    }
    |> reject_nil()
  end

  ## Response

  @spec response(map()) :: map()
  def response(%{"output" => output} = resp) when is_list(output) do
    text = output |> typed("message") |> Enum.map_join(&message_text/1)
    reasoning = output |> typed("reasoning") |> Enum.map_join(&summary_text/1)
    tool_calls = output |> typed("function_call") |> Enum.with_index() |> Enum.map(&tool_call/1)

    inner =
      %{"role" => "assistant", "content" => text}
      |> put_present("reasoning_content", nilify(reasoning))
      |> put_present("tool_calls", nilify_list(tool_calls))

    %{
      "id" => resp["id"],
      "object" => "chat.completion",
      "model" => resp["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => inner,
          "finish_reason" => finish_reason(resp["status"], tool_calls)
        }
      ],
      "usage" => usage(resp["usage"])
    }
  end

  defp message_text(%{"content" => parts}) when is_list(parts),
    do: parts |> typed("output_text") |> Enum.map_join(& &1["text"])

  defp message_text(_item), do: ""

  defp summary_text(%{"summary" => parts}) when is_list(parts),
    do: Enum.map_join(parts, fn part -> part["text"] || "" end)

  defp summary_text(_item), do: ""

  defp tool_call({item, index}) do
    %{
      "index" => index,
      "id" => item["call_id"],
      "type" => "function",
      "function" => %{"name" => item["name"], "arguments" => item["arguments"] || ""}
    }
  end

  defp finish_reason(_status, tool_calls) when tool_calls != [], do: "tool_calls"
  defp finish_reason("completed", _tool_calls), do: "stop"
  defp finish_reason("incomplete", _tool_calls), do: "length"
  defp finish_reason(_status, _tool_calls), do: nil

  defp usage(%{"input_tokens" => input, "output_tokens" => output} = totals) do
    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => totals["total_tokens"] || input + output
    }
  end

  defp usage(_), do: nil

  ## Streaming

  @spec stream_event(map()) :: [map()]
  def stream_event(%{"type" => "response.created"}), do: [chunk(%{"role" => "assistant"})]

  # A new function-call output item opens a tool call; `output_index` is stable
  # across its argument deltas, so it doubles as the OpenAI tool-call index.
  def stream_event(%{
        "type" => "response.output_item.added",
        "output_index" => index,
        "item" => %{"type" => "function_call"} = item
      }) do
    [
      chunk(%{
        "tool_calls" => [
          %{
            "index" => index,
            "id" => item["call_id"],
            "type" => "function",
            "function" => %{"name" => item["name"], "arguments" => ""}
          }
        ]
      })
    ]
  end

  def stream_event(%{"type" => "response.output_text.delta", "delta" => text}),
    do: [chunk(%{"content" => text})]

  def stream_event(%{"type" => "response.reasoning_summary_text.delta", "delta" => text}),
    do: [chunk(%{"reasoning_content" => text})]

  def stream_event(%{"type" => "response.reasoning_text.delta", "delta" => text}),
    do: [chunk(%{"reasoning_content" => text})]

  def stream_event(%{
        "type" => "response.function_call_arguments.delta",
        "output_index" => index,
        "delta" => json
      }),
      do: [chunk(%{"tool_calls" => [%{"index" => index, "function" => %{"arguments" => json}}]})]

  def stream_event(%{"type" => "response.completed", "response" => resp}) do
    tool_calls? =
      resp["output"] |> List.wrap() |> Enum.any?(&(&1["type"] == "function_call"))

    final = chunk(%{}, if(tool_calls?, do: "tool_calls", else: "stop"))

    case usage(resp["usage"]) do
      nil -> [final]
      usage -> [Map.put(final, "usage", usage)]
    end
  end

  def stream_event(%{"type" => "response.incomplete"}), do: [chunk(%{}, "length")]

  # in_progress, content_part/output_item bookkeeping, *.done recaps, and
  # anything unrecognized → nothing.
  def stream_event(_event), do: []

  defp chunk(delta, finish_reason \\ nil) do
    %{
      "object" => "chat.completion.chunk",
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }
  end

  ## Helpers

  defp typed(items, type), do: Enum.filter(items, &(&1["type"] == type))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp nilify(""), do: nil
  defp nilify(value), do: value

  defp nilify_list([]), do: nil
  defp nilify_list(list), do: list

  defp reject_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
