defmodule Airo.Adapters.CodexTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.Codex
  alias Airo.Config.{Deployment, Provider, Secret}

  defp jwt(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    header <> "." <> payload <> ".sig"
  end

  defp access_token,
    do: jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_123"}})

  defp context(opts \\ []) do
    provider =
      struct(
        %Provider{
          name: "codex",
          adapter_type: :codex,
          base_url: "https://chatgpt.com/backend-api/codex"
        },
        Keyword.get(opts, :provider,
          auth_kind: :oauth,
          credential: %Secret{kind: :oauth, value: access_token()}
        )
      )

    Context.new(provider,
      deployment: %Deployment{model_name: "gpt-5.1-codex"},
      opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    )
  end

  # Real backend shape: the terminal `response.completed` arrives with an
  # EMPTY output — the content only exists in the deltas and the
  # `output_item.done` recap.
  @sse """
  data: {"type":"response.created","response":{"id":"resp_1"}}

  data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}

  data: {"type":"response.output_text.delta","output_index":0,"delta":"He"}

  data: {"type":"response.output_text.delta","output_index":0,"delta":"llo"}

  data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}

  data: {"type":"response.completed","response":{"id":"resp_1","model":"gpt-5.4-mini","status":"completed","output":[],"usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}

  """

  describe "chat/2" do
    test "streams the Responses backend and folds the terminal object, with Codex headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          test_pid,
          {:req, conn.request_path,
           %{
             authorization: Plug.Conn.get_req_header(conn, "authorization"),
             account: Plug.Conn.get_req_header(conn, "chatgpt-account-id"),
             beta: Plug.Conn.get_req_header(conn, "openai-beta"),
             originator: Plug.Conn.get_req_header(conn, "originator")
           }, Jason.decode!(raw)}
        )

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, @sse)
      end)

      params = %{
        "model" => "gpt-5",
        "messages" => [
          %{"role" => "system", "content" => "sys"},
          %{"role" => "user", "content" => "yo"}
        ]
      }

      assert {:ok, openai} = Codex.chat(params, context())
      assert openai["object"] == "chat.completion"
      assert openai["choices"] |> hd() |> get_in(["message", "content"]) == "Hello"
      assert openai["choices"] |> hd() |> Map.get("finish_reason") == "stop"
      assert openai["usage"]["prompt_tokens"] == 4

      assert_received {:req, "/backend-api/codex/responses", headers, sent}
      assert headers.authorization == ["Bearer " <> access_token()]
      assert headers.account == ["acct_123"]
      assert headers.beta == ["responses=experimental"]
      assert headers.originator == ["codex_cli_rs"]

      assert sent["model"] == "gpt-5.1-codex"
      assert sent["instructions"] == "sys"
      assert sent["stream"] == true
      assert sent["store"] == false
    end

    test "prefers the terminal output when the backend populates it" do
      sse = """
      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"recap"}]}}

      data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"terminal"}]}]}}

      """

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      assert {:ok, openai} = Codex.chat(%{"messages" => []}, context())
      assert openai["choices"] |> hd() |> get_in(["message", "content"]) == "terminal"
    end

    test "maps a non-2xx to {:error, {:http_error, status, body}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"detail" => "rate limited"})
      end)

      assert {:error, {:http_error, 429, %{"detail" => _}}} =
               Codex.chat(%{"messages" => []}, context())
    end

    test "requires OAuth auth" do
      ctx = context(provider: [auth_kind: :api_key, credential: %Secret{value: "sk-x"}])
      assert Codex.chat(%{"messages" => []}, ctx) == {:error, :oauth_required}
    end
  end

  describe "stream/4" do
    test "normalizes the Responses SSE stream to OpenAI delta chunks" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, @sse)
      end)

      assert {:ok, chunks} =
               Codex.stream(%{"messages" => []}, context(), [], fn chunk, acc ->
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
      assert Enum.any?(chunks, &(&1["usage"]["total_tokens"] == 6))
    end
  end

  describe "list_models/1" do
    test "GETs the version-gated /models catalog with Codex headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(
          test_pid,
          {:req, conn.request_path, conn.query_string,
           Plug.Conn.get_req_header(conn, "chatgpt-account-id")}
        )

        Req.Test.json(conn, %{
          "models" => [
            %{"slug" => "gpt-5.6-terra", "display_name" => "GPT-5.6-Terra"},
            %{"slug" => "gpt-5.4-mini", "display_name" => "GPT-5.4-Mini"}
          ]
        })
      end)

      assert Codex.list_models(context()) == {:ok, ["gpt-5.6-terra", "gpt-5.4-mini"]}

      assert_received {:req, "/backend-api/codex/models", "client_version=2.0.0", ["acct_123"]}
    end

    test "a configured :models list short-circuits the live lookup" do
      original = Application.get_env(:airo, Codex, [])
      Application.put_env(:airo, Codex, Keyword.put(original, :models, ["pinned-model"]))
      on_exit(fn -> Application.put_env(:airo, Codex, original) end)

      assert Codex.list_models(context()) == {:ok, ["pinned-model"]}
    end
  end
end
