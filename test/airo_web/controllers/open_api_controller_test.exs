defmodule AiroWeb.OpenApiControllerTest do
  use AiroWeb.ConnCase, async: true

  test "GET /openapi serves the OpenAPI document", %{conn: conn} do
    body = conn |> get(~p"/openapi") |> json_response(200)

    assert body["openapi"] == "3.0.0"
    assert body["info"]["title"] == "Airo Gateway"

    for path <- ~w(/v1/chat/completions /v1/embeddings /v1/rerank /v1/audio/speech /v1/models) do
      assert Map.has_key?(body["paths"], path)
    end

    assert get_in(body, ["components", "securitySchemes", "clientKey", "scheme"]) == "bearer"
  end
end
