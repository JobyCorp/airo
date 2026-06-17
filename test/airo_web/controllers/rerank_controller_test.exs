defmodule AiroWeb.RerankControllerTest do
  use AiroWeb.ConnCase, async: true

  alias Airo.Config

  defp seed_rerank_alias do
    {:ok, provider} =
      Config.create_provider(%{
        name: "inf",
        adapter_type: :infinity,
        base_url: "http://inf:7997",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: "bge-reranker",
        capabilities: [:rerank]
      })

    {:ok, _} =
      Config.create_alias(%{
        name: "rerank-std",
        capability: :rerank,
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

  test "POST /v1/rerank dispatches :rerank and returns results", %{conn: conn} do
    seed_rerank_alias()

    Req.Test.stub(Airo.TestStub, fn upstream ->
      Req.Test.json(upstream, %{"results" => [%{"index" => 1, "relevance_score" => 0.8}]})
    end)

    conn =
      conn
      |> authed(mint())
      |> post(~p"/v1/rerank", %{
        "model" => "rerank-std",
        "query" => "q",
        "documents" => ["a", "b"]
      })

    assert json_response(conn, 200)["results"] |> hd() |> Map.get("relevance_score") == 0.8
    assert get_resp_header(conn, "x-gateway-model") == ["bge-reranker"]
  end

  test "404 for an unknown rerank model", %{conn: conn} do
    conn =
      conn
      |> authed(mint())
      |> post(~p"/v1/rerank", %{"model" => "ghost", "query" => "q", "documents" => []})

    assert json_response(conn, 404)["error"]["code"] == "model_not_found"
  end
end
