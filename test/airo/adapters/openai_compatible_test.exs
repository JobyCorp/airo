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

  describe "chat/2 — reasoning key" do
    # Newer vLLM emits `reasoning`; Airo's other adapters emit `reasoning_content`.
    test "mirrors a vLLM `reasoning` into `reasoning_content`, keeping the original" do
      upstream =
        put_in(@completion, ["choices", Access.at(0), "message"], %{
          "role" => "assistant",
          "content" => "5",
          "reasoning" => "Ball is 5 cents."
        })

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, upstream) end)

      assert {:ok, body} = OpenAICompatible.chat(%{"messages" => []}, context(__MODULE__))
      message = body["choices"] |> hd() |> Map.fetch!("message")

      assert message["reasoning_content"] == "Ball is 5 cents."
      assert message["reasoning"] == "Ball is 5 cents."
      assert message["content"] == "5"
    end

    test "leaves a message alone when reasoning is null, empty, or already normalised" do
      for reasoning <- [nil, ""] do
        upstream =
          put_in(@completion, ["choices", Access.at(0), "message"], %{
            "role" => "assistant",
            "content" => "5",
            "reasoning" => reasoning
          })

        Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, upstream) end)
        assert {:ok, body} = OpenAICompatible.chat(%{"messages" => []}, context(__MODULE__))

        refute body["choices"]
               |> hd()
               |> Map.fetch!("message")
               |> Map.has_key?("reasoning_content")
      end

      upstream =
        put_in(@completion, ["choices", Access.at(0), "message"], %{
          "role" => "assistant",
          "content" => "5",
          "reasoning" => "newer",
          "reasoning_content" => "already here"
        })

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, upstream) end)
      assert {:ok, body} = OpenAICompatible.chat(%{"messages" => []}, context(__MODULE__))

      assert get_in(body, ["choices", Access.at(0), "message", "reasoning_content"]) ==
               "already here"
    end

    test "a body without choices (embeddings, errors) passes through untouched" do
      assert OpenAICompatible.normalize_reasoning(%{"data" => [1]}) == %{"data" => [1]}
      assert OpenAICompatible.normalize_reasoning("raw") == "raw"
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

    @reasoning_sse """
    data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}

    data: {"choices":[{"index":0,"delta":{"reasoning":"Think"}}]}

    data: {"choices":[{"index":0,"delta":{"reasoning":"ing."}}]}

    data: {"choices":[{"index":0,"delta":{"content":"5"},"finish_reason":"stop"}]}

    data: [DONE]

    """

    test "mirrors `reasoning` deltas into `reasoning_content` before the reducer sees them" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, @reasoning_sse)
      end)

      assert {:ok, chunks} =
               OpenAICompatible.stream(%{"messages" => []}, context(__MODULE__), [], fn chunk,
                                                                                        acc ->
                 acc ++ [chunk]
               end)

      deltas = Enum.map(chunks, &get_in(&1, ["choices", Access.at(0), "delta"]))

      assert Enum.map_join(deltas, &(&1["reasoning_content"] || "")) == "Thinking."
      # The newer key is kept alongside, and content deltas gain nothing.
      assert Enum.map_join(deltas, &(&1["reasoning"] || "")) == "Thinking."
      refute List.last(deltas) |> Map.has_key?("reasoning_content")
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

  describe "speech/2" do
    test "returns binary audio tagged with its content type" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg", nil)
        |> Plug.Conn.send_resp(200, <<1, 2, 3, 4>>)
      end)

      ctx = context(__MODULE__, deployment: %Deployment{model_name: "tts-1"})

      assert {:ok, {:audio, "audio/mpeg", <<1, 2, 3, 4>>}} =
               OpenAICompatible.speech(%{"model" => "voice", "input" => "hi"}, ctx)
    end
  end

  describe "transcribe/2" do
    test "uploads the file as multipart and returns the JSON transcript" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        [content_type] = Plug.Conn.get_req_header(conn, "content-type")
        send(test_pid, {:content_type, content_type})
        Req.Test.json(conn, %{"text" => "hello world"})
      end)

      path = Path.join(System.tmp_dir!(), "airo-#{System.unique_integer([:positive])}.wav")
      File.write!(path, "RIFFfake")
      upload = %Plug.Upload{path: path, filename: "a.wav", content_type: "audio/wav"}

      ctx = context(__MODULE__, deployment: %Deployment{model_name: "whisper-1"})

      assert {:ok, %{"text" => "hello world"}} =
               OpenAICompatible.transcribe(%{"model" => "stt", "file" => upload}, ctx)

      assert_received {:content_type, "multipart/form-data" <> _}
      File.rm(path)
    end

    test "errors when no file is provided" do
      ctx = context(__MODULE__, deployment: %Deployment{model_name: "whisper-1"})

      assert {:error, {:invalid_request, :missing_file}} =
               OpenAICompatible.transcribe(%{"model" => "stt"}, ctx)
    end
  end

  describe "list_models/1" do
    test "GETs /models and returns the catalog's ids" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:method, conn.method, conn.request_path})

        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [
            %{"id" => "qwen3.5-9b", "object" => "model"},
            %{"id" => "nomic-embed", "object" => "model"}
          ]
        })
      end)

      assert {:ok, ["qwen3.5-9b", "nomic-embed"]} =
               OpenAICompatible.list_models(context(__MODULE__))

      assert_received {:method, "GET", "/v1/models"}
    end

    test "surfaces an upstream error status" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      assert {:error, {:http_error, 503, _}} = OpenAICompatible.list_models(context(__MODULE__))
    end
  end
end
