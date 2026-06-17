defmodule AiroWeb.EmbeddingsControllerTest do
  use AiroWeb.ConnCase, async: true

  alias Airo.Config

  @embedding %{
    "object" => "list",
    "data" => [%{"object" => "embedding", "index" => 0, "embedding" => [0.1, 0.2, 0.3]}],
    "model" => "bge-m3",
    "usage" => %{"prompt_tokens" => 3, "total_tokens" => 3}
  }

  defp seed_embed_alias do
    {:ok, provider} =
      Config.create_provider(%{
        name: "emb",
        adapter_type: :vllm,
        base_url: "http://emb:8000/v1",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "bge-m3",
        capabilities: [:embeddings]
      })

    {:ok, _} =
      Config.create_alias(%{
        name: "embed-fast",
        capability: :embeddings,
        strategy: :priority,
        candidates: [%{deployment_id: deployment.id, weight: 100, priority: 0}]
      })

    :ok
  end

  defp mint,
    do:
      elem(
        Config.mint_client_key(%{
          name: "k-#{System.unique_integer([:positive])}",
          allowed_aliases: ["*"]
        }),
        1
      ).key

  defp authed(conn, key), do: put_req_header(conn, "authorization", "Bearer " <> key)

  test "POST /v1/embeddings resolves, dispatches :embed, and returns the response", %{conn: conn} do
    seed_embed_alias()
    test_pid = self()

    Req.Test.stub(Airo.TestStub, fn upstream ->
      send(test_pid, {:path, upstream.request_path})
      Req.Test.json(upstream, @embedding)
    end)

    conn =
      conn
      |> authed(mint())
      |> post(~p"/v1/embeddings", %{"model" => "embed-fast", "input" => "hello"})

    assert json_response(conn, 200)["data"] |> hd() |> Map.get("embedding") == [0.1, 0.2, 0.3]
    assert get_resp_header(conn, "x-gateway-model") == ["bge-m3"]
    assert_received {:path, "/v1/embeddings"}
  end

  test "404 for an unknown embeddings model", %{conn: conn} do
    conn =
      conn |> authed(mint()) |> post(~p"/v1/embeddings", %{"model" => "ghost", "input" => "x"})

    assert json_response(conn, 404)["error"]["code"] == "model_not_found"
  end

  test "401 without a client key", %{conn: conn} do
    conn = post(conn, ~p"/v1/embeddings", %{"model" => "embed-fast", "input" => "x"})
    assert json_response(conn, 401)
  end
end
