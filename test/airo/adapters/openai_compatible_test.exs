defmodule Airo.Adapters.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.OpenAICompatible
  alias Airo.Config.{Deployment, Provider, Secret}

  # A chat-completion body the stub echoes back on success.
  @completion %{
    "id" => "chatcmpl-1",
    "object" => "chat.completion",
    "model" => "qwen3.5-9b",
    "choices" => [
      %{
        "index" => 0,
        "message" => %{"role" => "assistant", "content" => "hi"},
        "finish_reason" => "stop"
      }
    ]
  }

  defp context(stub, fields \\ []) do
    provider =
      struct(
        %Provider{
          name: "local",
          adapter_type: :vllm,
          base_url: "http://upstream:8000/v1",
          auth_kind: :none
        },
        Keyword.get(fields, :provider, [])
      )

    Context.new(provider,
      deployment: fields[:deployment],
      opts: [req_options: [plug: {Req.Test, stub}]]
    )
  end

  describe "chat/2 — success" do
    test "forwards the body to /chat/completions and returns the decoded response" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:upstream, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, @completion)
      end)

      params = %{
        "model" => "chat-standard",
        "messages" => [%{"role" => "user", "content" => "yo"}]
      }

      assert {:ok, body} = OpenAICompatible.chat(params, context(__MODULE__))

      assert body["choices"] |> hd() |> get_in(["message", "content"]) == "hi"
      assert_received {:upstream, "/v1/chat/completions", sent}
      assert sent["messages"] == [%{"role" => "user", "content" => "yo"}]
    end

    test "overrides the model with the chosen deployment's model_name" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:model, Jason.decode!(body)["model"]})
        Req.Test.json(conn, @completion)
      end)

      ctx = context(__MODULE__, deployment: %Deployment{model_name: "qwen3.5-9b"})
      params = %{"model" => "chat-standard", "messages" => []}

      assert {:ok, _} = OpenAICompatible.chat(params, ctx)
      assert_received {:model, "qwen3.5-9b"}
    end
  end

  describe "chat/2 — auth" do
    test "injects a Bearer token from the provider credential" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, @completion)
      end)

      ctx =
        context(__MODULE__,
          provider: [
            auth_kind: :api_key,
            credential_id: 1,
            credential: %Secret{value: "sk-test-123"}
          ]
        )

      assert {:ok, _} = OpenAICompatible.chat(%{"messages" => []}, ctx)
      assert_received {:auth, ["Bearer sk-test-123"]}
    end

    test "sends no authorization header for a keyless provider" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, @completion)
      end)

      assert {:ok, _} = OpenAICompatible.chat(%{"messages" => []}, context(__MODULE__))
      assert_received {:auth, []}
    end
  end

  describe "chat/2 — failures" do
    test "maps a non-2xx upstream to {:error, {:http_error, status, body}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "overloaded"})
      end)

      assert {:error, {:http_error, 503, %{"error" => "overloaded"}}} =
               OpenAICompatible.chat(%{"messages" => []}, context(__MODULE__))
    end

    test "maps a transport failure to {:error, {:transport_error, _}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transport_error, _reason}} =
               OpenAICompatible.chat(%{"messages" => []}, context(__MODULE__))
    end
  end

  describe "stream/4" do
    @sse """
    data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}

    data: {"choices":[{"index":0,"delta":{"content":"He"}}]}

    data: {"choices":[{"index":0,"delta":{"content":"llo"},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    test "folds each SSE delta chunk through the reducer, dropping [DONE]" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, @sse)
      end)

      ctx = context(__MODULE__, deployment: %Deployment{model_name: "qwen3.5-9b"})

      assert {:ok, chunks} =
               OpenAICompatible.stream(%{"messages" => []}, ctx, [], fn chunk, acc ->
                 acc ++ [chunk]
               end)

      # Four deltas, [DONE] consumed (not forwarded).
      assert length(chunks) == 4

      content =
        chunks
        |> Enum.map(&get_in(&1, ["choices", Access.at(0), "delta", "content"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.join()

      assert content == "Hello"
    end

    test "sets stream:true on the upstream request body" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, "data: [DONE]\n\n")
      end)

      ctx = context(__MODULE__, deployment: %Deployment{model_name: "m"})

      assert {:ok, []} =
               OpenAICompatible.stream(%{"messages" => []}, ctx, [], fn c, acc -> [c | acc] end)

      assert_received {:sent, %{"stream" => true, "model" => "m"}}
    end

    test "maps a non-2xx stream to {:error, {:http_error, status, body}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      ctx = context(__MODULE__, deployment: %Deployment{model_name: "m"})

      assert {:error, {:http_error, 500, %{"error" => "boom"}}, []} =
               OpenAICompatible.stream(%{"messages" => []}, ctx, [], fn c, acc -> [c | acc] end)
    end
  end
end
