defmodule AiroWeb.ChatAffinityTest do
  use AiroWeb.ConnCase, async: true

  alias Airo.{Config, Repo}
  alias Airo.Usage.UsageRecord

  @completion %{
    "id" => "chatcmpl-1",
    "object" => "chat.completion",
    "choices" => [
      %{
        "index" => 0,
        "message" => %{"role" => "assistant", "content" => "hi"},
        "finish_reason" => "stop"
      }
    ]
  }

  setup do
    for name <- ["ca", "cb"] do
      {:ok, p} =
        Config.create_provider(%{
          name: name,
          adapter_type: :vllm,
          base_url: "http://#{name}/v1",
          auth_kind: :none
        })

      {:ok, _} =
        Config.create_deployment(%{provider_id: p.id, model_name: "m", capabilities: [:chat]})
    end

    candidates =
      Config.list_deployments()
      |> Enum.filter(&(&1.model_name == "m"))
      |> Enum.map(&%{deployment_id: &1.id, weight: 100, priority: 0})

    {:ok, _} =
      Config.create_alias(%{
        name: "agent-fast",
        capability: :chat,
        strategy: :affinity,
        candidates: candidates
      })

    {:ok, key} = Config.mint_client_key(%{name: "k-affinity", allowed_aliases: ["*"]})
    test = self()

    Req.Test.stub(Airo.TestStub, fn upstream ->
      {:ok, raw, upstream} = Plug.Conn.read_body(upstream)
      send(test, {:upstream, upstream.host, Jason.decode!(raw)})
      Req.Test.json(upstream, @completion)
    end)

    %{raw_key: key.key}
  end

  defp post_chat(conn, raw_key, extra, trace_id) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw_key)
    |> put_req_header("x-gateway-trace-id", trace_id)
    |> post(
      ~p"/v1/chat/completions",
      Map.merge(
        %{"model" => "agent-fast", "messages" => [%{"role" => "user", "content" => "yo"}]},
        extra
      )
    )
  end

  test "rounds of one session reach one card; header and request log carry the outcome",
       %{conn: conn, raw_key: raw_key} do
    route = %{"route" => %{"affinity" => "helm-session-1"}}

    first = post_chat(conn, raw_key, route, "gt_aff_1")
    assert get_resp_header(first, "x-gateway-affinity") == ["assigned"]
    assert_received {:upstream, host, _}

    for i <- 2..5 do
      conn = post_chat(build_conn(), raw_key, route, "gt_aff_#{i}")
      assert get_resp_header(conn, "x-gateway-affinity") == ["hit"]
      assert_received {:upstream, ^host, _}
    end

    assert %UsageRecord{affinity: :assigned} = Repo.get_by(UsageRecord, trace_id: "gt_aff_1")
    assert %UsageRecord{affinity: :hit} = Repo.get_by(UsageRecord, trace_id: "gt_aff_2")
  end

  test "route is absent from the upstream body", %{conn: conn, raw_key: raw_key} do
    post_chat(conn, raw_key, %{"route" => %{"affinity" => "s"}}, "gt_aff_body")

    assert_received {:upstream, _host, sent}
    refute Map.has_key?(sent, "route")
    refute Map.has_key?(sent, "affinity")
  end

  test "no key reports none", %{conn: conn, raw_key: raw_key} do
    conn = post_chat(conn, raw_key, %{}, "gt_aff_none")

    assert get_resp_header(conn, "x-gateway-affinity") == ["none"]
    assert %UsageRecord{affinity: :none} = Repo.get_by(UsageRecord, trace_id: "gt_aff_none")
  end

  test "a key over 128 bytes is a 400", %{conn: conn, raw_key: raw_key} do
    route = %{"route" => %{"affinity" => String.duplicate("x", 129)}}
    conn = post_chat(conn, raw_key, route, "gt_aff_long")

    assert json_response(conn, 400)["error"]["code"] == "invalid_affinity"
    refute_received {:upstream, _, _}
  end

  test "streaming sends the header up front and the outcome in gateway.metadata",
       %{conn: conn, raw_key: raw_key} do
    Req.Test.stub(Airo.TestStub, fn upstream ->
      upstream
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, """
      data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}

      data: [DONE]

      """)
    end)

    conn =
      post_chat(conn, raw_key, %{"stream" => true, "route" => %{"affinity" => "s"}}, "gt_aff_sse")

    assert get_resp_header(conn, "x-gateway-affinity") == ["assigned"]
    assert conn.resp_body =~ ~s("affinity":"assigned")
  end
end
