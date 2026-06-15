defmodule Airo.Adapters.AnthropicTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.Anthropic
  alias Airo.Config.{Deployment, Provider, Secret}

  @message %{
    "id" => "msg_1",
    "type" => "message",
    "role" => "assistant",
    "model" => "claude-x",
    "content" => [%{"type" => "text", "text" => "hi there"}],
    "stop_reason" => "end_turn",
    "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
  }

  defp context(opts \\ []) do
    provider =
      struct(
        %Provider{
          name: "anthropic",
          adapter_type: :anthropic,
          base_url: "https://api.anthropic.com"
        },
        Keyword.get(opts, :provider,
          auth_kind: :api_key,
          credential: %Secret{value: "sk-ant-123"}
        )
      )

    Context.new(provider,
      deployment: %Deployment{model_name: "claude-x"},
      opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    )
  end

  describe "chat/2" do
    test "translates request/response and sends Anthropic auth headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          test_pid,
          {:req, conn.request_path, Plug.Conn.get_req_header(conn, "x-api-key"),
           Jason.decode!(raw)}
        )

        Req.Test.json(conn, @message)
      end)

      params = %{
        "model" => "claude-deep",
        "messages" => [
          %{"role" => "system", "content" => "sys"},
          %{"role" => "user", "content" => "yo"}
        ]
      }

      assert {:ok, openai} = Anthropic.chat(params, context())
      assert openai["choices"] |> hd() |> get_in(["message", "content"]) == "hi there"

      assert_received {:req, "/v1/messages", ["sk-ant-123"], sent}
      assert sent["model"] == "claude-x"
      assert sent["system"] == "sys"
      assert sent["max_tokens"] == 4096
    end

    test "maps a non-2xx to {:error, {:http_error, status, body}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"type" => "error", "error" => %{"message" => "overloaded"}})
      end)

      assert {:error, {:http_error, 429, %{"error" => _}}} =
               Anthropic.chat(%{"messages" => []}, context())
    end
  end

  describe "stream/4" do
    @sse """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","model":"claude-x"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"He"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"llo"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    test "normalizes the Anthropic SSE stream to OpenAI delta chunks" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, @sse)
      end)

      assert {:ok, chunks} =
               Anthropic.stream(%{"messages" => []}, context(), [], fn chunk, acc ->
                 acc ++ [chunk]
               end)

      assert Enum.all?(chunks, &(&1["object"] == "chat.completion.chunk"))

      content =
        chunks
        |> Enum.map(&hd(&1["choices"])["delta"]["content"])
        |> Enum.reject(&is_nil/1)
        |> Enum.join()

      assert content == "Hello"
      assert Enum.any?(chunks, &(hd(&1["choices"])["finish_reason"] == "stop"))
    end
  end
end
