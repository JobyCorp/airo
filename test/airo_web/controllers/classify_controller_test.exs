defmodule AiroWeb.ClassifyControllerTest do
  use AiroWeb.ConnCase, async: true

  alias Airo.Config

  defp seed_classify_alias do
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
        model_name: "go-emotions",
        capabilities: [:classify]
      })

    {:ok, _} =
      Config.create_alias(%{
        name: "classify-std",
        capability: :classify,
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

  test "POST /v1/classify dispatches :classify and returns results", %{conn: conn} do
    seed_classify_alias()

    Req.Test.stub(Airo.TestStub, fn upstream ->
      Req.Test.json(upstream, %{
        "object" => "classify",
        "data" => [[%{"label" => "joy", "score" => 0.92}]],
        "model" => "go-emotions"
      })
    end)

    conn =
      conn
      |> authed(mint())
      |> post(~p"/v1/classify", %{"model" => "classify-std", "input" => ["I am happy"]})

    body = json_response(conn, 200)
    assert body["data"] |> hd() |> hd() |> Map.get("label") == "joy"
    assert get_resp_header(conn, "x-gateway-model") == ["go-emotions"]
  end

  test "404 for an unknown classify model", %{conn: conn} do
    conn =
      conn
      |> authed(mint())
      |> post(~p"/v1/classify", %{"model" => "ghost", "input" => ["x"]})

    assert json_response(conn, 404)["error"]["code"] == "model_not_found"
  end
end
