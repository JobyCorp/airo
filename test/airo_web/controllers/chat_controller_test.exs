defmodule AiroWeb.ChatControllerTest do
  use AiroWeb.ConnCase, async: true

  alias Airo.Config

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
        capability: :chat
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

      conn = conn |> authed(mint()) |> post(~p"/v1/chat/completions", body())
      assert json_response(conn, 503)["error"]["message"] == "overloaded"
    end
  end

  describe "POST /v1/chat/completions — auth & resolution errors" do
    test "401 without a client key", %{conn: conn} do
      conn = post(conn, ~p"/v1/chat/completions", body())
      assert json_response(conn, 401)["error"]["code"] == "invalid_api_key"
    end

    test "404 for an unknown model/alias", %{conn: conn} do
      conn = conn |> authed(mint()) |> post(~p"/v1/chat/completions", body(%{"model" => "ghost"}))
      assert json_response(conn, 404)["error"]["code"] == "model_not_found"
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
end
