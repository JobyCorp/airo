defmodule AiroWeb.ChatControllerTest do
  use AiroWeb.ConnCase, async: true

  alias Airo.{Config, Repo}
  alias Airo.Usage.UsageRecord

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

  defp seed_alias do
    {:ok, provider} =
      Config.create_provider(%{
        name: "local",
        adapter_type: :vllm,
        base_url: "http://upstream:8000/v1",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "qwen3.5-9b",
        capabilities: [:chat]
      })

    {:ok, _alias} =
      Config.create_alias(%{
        name: "chat-standard",
        capability: :chat,
        strategy: :priority,
        candidates: [%{deployment_id: deployment.id, weight: 100, priority: 0}]
      })

    :ok
  end

  defp mint(allowed \\ ["*"]) do
    {:ok, key} =
      Config.mint_client_key(%{
        name: "k-#{System.unique_integer([:positive])}",
        allowed_aliases: allowed
      })

    key.key
  end

  defp authed(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer " <> raw_key)

  defp body(extra \\ %{}),
    do:
      Map.merge(
        %{"model" => "chat-standard", "messages" => [%{"role" => "user", "content" => "yo"}]},
        extra
      )

  describe "POST /v1/chat/completions — happy path" do
    setup do
      seed_alias()
      :ok
    end

    test "resolves the alias, dispatches, and returns the OpenAI response", %{conn: conn} do
      test_pid = self()

      Req.Test.stub(Airo.TestStub, fn upstream ->
        {:ok, raw, upstream} = Plug.Conn.read_body(upstream)
        send(test_pid, {:upstream, upstream.request_path, Jason.decode!(raw)})
        Req.Test.json(upstream, @completion)
      end)

      conn = conn |> authed(mint()) |> post(~p"/v1/chat/completions", body())

      assert json_response(conn, 200)["choices"] |> hd() |> get_in(["message", "content"]) == "hi"

      # Upstream saw the deployment's concrete model, not the alias.
      assert_received {:upstream, "/v1/chat/completions", sent}
      assert sent["model"] == "qwen3.5-9b"
      assert sent["messages"] == [%{"role" => "user", "content" => "yo"}]
    end

    test "passes the upstream status through when it returns an OpenAI error", %{conn: conn} do
      Req.Test.stub(Airo.TestStub, fn upstream ->
        upstream
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{
          "error" => %{"message" => "overloaded", "type" => "server_error", "code" => nil}
        })
      end)

      conn =
        conn
        |> put_req_header("x-gateway-trace-id", "gt_upstream_error")
        |> authed(mint())
        |> post(~p"/v1/chat/completions", body())

      assert json_response(conn, 503)["error"]["message"] == "overloaded"

      assert %UsageRecord{
               trace_id: "gt_upstream_error",
               request_model: "chat-standard",
               outcome: :error,
               error_code: nil,
               http_status: 503,
               upstream_status: 503
             } = Repo.get_by(UsageRecord, trace_id: "gt_upstream_error")
    end
  end

  describe "POST /v1/chat/completions — auth & resolution errors" do
    test "401 without a client key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-gateway-trace-id", "gt_auth_error")
        |> post(~p"/v1/chat/completions", body())

      assert json_response(conn, 401)["error"]["code"] == "invalid_api_key"

      assert %UsageRecord{
               trace_id: "gt_auth_error",
               request_model: "chat-standard",
               capability: :chat,
               outcome: :error,
               error_code: "invalid_api_key",
               http_status: 401
             } = Repo.get_by(UsageRecord, trace_id: "gt_auth_error")
    end

    test "404 for an unknown model/alias", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-gateway-trace-id", "gt_model_error")
        |> authed(mint())
        |> post(~p"/v1/chat/completions", body(%{"model" => "ghost"}))

      assert json_response(conn, 404)["error"]["code"] == "model_not_found"

      assert %UsageRecord{
               trace_id: "gt_model_error",
               request_model: "ghost",
               outcome: :error,
               error_code: "model_not_found",
               http_status: 404
             } = Repo.get_by(UsageRecord, trace_id: "gt_model_error")
    end

    test "403 when the client key is not scoped to the alias", %{conn: conn} do
      seed_alias()
      conn = conn |> authed(mint(["embed-fast"])) |> post(~p"/v1/chat/completions", body())
      assert json_response(conn, 403)["error"]["code"] == "model_not_authorized"
    end

    test "400 when model is missing", %{conn: conn} do
      conn = conn |> authed(mint()) |> post(~p"/v1/chat/completions", %{"messages" => []})
      assert json_response(conn, 400)["error"]["code"] == "missing_model"
    end
  end

  describe "POST /v1/chat/completions — non-streaming transparency" do
    setup do
      seed_alias()
      :ok
    end

    test "attaches x-gateway-* headers including latency", %{conn: conn} do
      Req.Test.stub(Airo.TestStub, fn upstream -> Req.Test.json(upstream, @completion) end)

      conn =
        conn
        |> put_req_header("x-gateway-trace-id", "gt_chat_test")
        |> authed(mint())
        |> post(~p"/v1/chat/completions", body())

      assert json_response(conn, 200)
      assert get_resp_header(conn, "x-gateway-trace-id") == ["gt_chat_test"]
      assert get_resp_header(conn, "x-gateway-provider") == ["local"]
      assert get_resp_header(conn, "x-gateway-model") == ["qwen3.5-9b"]
      assert get_resp_header(conn, "x-gateway-fallback") == ["false"]
      assert [latency] = get_resp_header(conn, "x-gateway-latency-ms")
      assert String.to_integer(latency) >= 0

      assert %UsageRecord{trace_id: "gt_chat_test"} =
               Repo.get_by(UsageRecord, alias_name: "chat-standard")
    end
  end

  describe "POST /v1/chat/completions — streaming" do
    setup do
      seed_alias()
      :ok
    end

    @sse """
    data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}

    data: {"choices":[{"index":0,"delta":{"content":"He"}}]}

    data: {"choices":[{"index":0,"delta":{"content":"llo"},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    test "streams SSE deltas, a transparency trailer, and [DONE]", %{conn: conn} do
      Req.Test.stub(Airo.TestStub, fn upstream ->
        upstream
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, @sse)
      end)

      conn =
        conn
        |> put_req_header("x-gateway-trace-id", "gt_stream_test")
        |> authed(mint())
        |> post(~p"/v1/chat/completions", body(%{"stream" => true}))

      assert conn.status == 200
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")

      # Up-front transparency headers (latency only lands in the trailer here).
      assert get_resp_header(conn, "x-gateway-trace-id") == ["gt_stream_test"]
      assert get_resp_header(conn, "x-gateway-model") == ["qwen3.5-9b"]
      assert get_resp_header(conn, "x-gateway-latency-ms") == []

      body = conn.resp_body
      assert body =~ ~s("content":"He")
      assert body =~ ~s("content":"llo")
      refute body =~ "[DONE]\"]"
      # Trailer metadata event with latency, then the OpenAI sentinel last.
      assert body =~ "event: gateway.metadata"
      assert body =~ ~s("trace_id":"gt_stream_test")
      assert body =~ "latency_ms"
      assert String.ends_with?(String.trim_trailing(body), "data: [DONE]")
    end

    test "returns a clean HTTP error when the stream fails before any output", %{conn: conn} do
      # Single candidate, upstream errors before emitting → nothing committed, so
      # the gateway can still answer with a proper status (no SSE was opened).
      Req.Test.stub(Airo.TestStub, fn upstream ->
        upstream
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"message" => "boom", "type" => "server_error"}})
      end)

      conn =
        conn
        |> put_req_header("x-gateway-trace-id", "gt_stream_prebyte_error")
        |> authed(mint())
        |> post(~p"/v1/chat/completions", body(%{"stream" => true}))

      assert json_response(conn, 500)["error"]["message"] == "boom"
      refute conn.resp_body =~ "event:"

      assert %UsageRecord{
               trace_id: "gt_stream_prebyte_error",
               request_model: "chat-standard",
               outcome: :error,
               error_code: nil,
               http_status: 500,
               upstream_status: 500
             } = Repo.get_by(UsageRecord, trace_id: "gt_stream_prebyte_error")
    end

    test "401 still applies on the streaming path (auth runs before streaming)", %{conn: conn} do
      conn = post(conn, ~p"/v1/chat/completions", body(%{"stream" => true}))
      assert json_response(conn, 401)["error"]["code"] == "invalid_api_key"
    end
  end

  describe "POST /v1/chat/completions — routing & failover" do
    @sse_up """
    data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}

    data: [DONE]

    """

    defp two_candidate_alias do
      {:ok, down} =
        Config.create_provider(%{
          name: "down",
          adapter_type: :vllm,
          base_url: "http://down/v1",
          auth_kind: :none
        })

      {:ok, up} =
        Config.create_provider(%{
          name: "up",
          adapter_type: :vllm,
          base_url: "http://up/v1",
          auth_kind: :none
        })

      {:ok, dd} =
        Config.create_deployment(%{provider_id: down.id, model_name: "md", capabilities: [:chat]})

      {:ok, du} =
        Config.create_deployment(%{provider_id: up.id, model_name: "mu", capabilities: [:chat]})

      {:ok, _} =
        Config.create_alias(%{
          name: "chat-standard",
          capability: :chat,
          strategy: :priority,
          candidates: [
            %{deployment_id: dd.id, weight: 100, priority: 0},
            %{deployment_id: du.id, weight: 100, priority: 1}
          ]
        })

      :ok
    end

    test "non-streaming fails over and reports it in x-gateway headers", %{conn: conn} do
      two_candidate_alias()

      Req.Test.stub(Airo.TestStub, fn upstream ->
        case upstream.host do
          "down" -> Req.Test.transport_error(upstream, :econnrefused)
          "up" -> Req.Test.json(upstream, @completion)
        end
      end)

      conn = conn |> authed(mint()) |> post(~p"/v1/chat/completions", body())

      assert json_response(conn, 200)
      assert get_resp_header(conn, "x-gateway-provider") == ["up"]
      assert get_resp_header(conn, "x-gateway-fallback") == ["true"]
    end

    test "streaming fails over before the first byte and reports it in the trailer", %{conn: conn} do
      two_candidate_alias()

      Req.Test.stub(Airo.TestStub, fn upstream ->
        case upstream.host do
          "down" ->
            Req.Test.transport_error(upstream, :econnrefused)

          "up" ->
            upstream
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_resp(200, @sse_up)
        end
      end)

      conn = conn |> authed(mint()) |> post(~p"/v1/chat/completions", body(%{"stream" => true}))

      assert conn.status == 200
      assert conn.resp_body =~ ~s("content":"ok")
      assert conn.resp_body =~ ~s("fallback_used":true)
      assert conn.resp_body =~ "data: [DONE]"
    end

    test "409 for an unavailable strict binding", %{conn: conn} do
      seed_alias()
      body = body(%{"route" => %{"binding" => "vllm:ghost"}})
      conn = conn |> authed(mint()) |> post(~p"/v1/chat/completions", body)
      assert json_response(conn, 409)["error"]["code"] == "selected_binding_unavailable"
    end
  end
end
