defmodule AiroWeb.OpenApiControllerTest do
  use AiroWeb.ConnCase, async: true

  test "GET /openapi serves the OpenAPI document", %{conn: conn} do
    body = conn |> get(~p"/openapi") |> json_response(200)

    assert body["openapi"] == "3.0.0"
    assert body["info"]["title"] == "Airo Gateway"

    for path <-
          ~w(/v1/chat/completions /v1/embeddings /v1/rerank /v1/classify /v1/audio/speech
             /v1/audio/transcriptions /v1/models) do
      assert Map.has_key?(body["paths"], path)
    end

    assert get_in(body, ["components", "securitySchemes", "clientKey", "scheme"]) == "bearer"
  end

  test "the spec documents request/response schemas and Airo's additions", %{conn: conn} do
    body = conn |> get(~p"/openapi") |> json_response(200)
    schemas = body["components"]["schemas"]

    # Request bodies are schema'd (not just paths).
    assert get_in(body, ["paths", "/v1/chat/completions", "post", "requestBody"])

    # The Route object (class/tools/vision) is documented.
    route_props = schemas["Route"]["properties"]
    assert Map.has_key?(route_props, "class")
    assert Map.has_key?(route_props, "vision")

    # /v1/models entries advertise capabilities.
    assert get_in(schemas, [
             "ModelList",
             "properties",
             "data",
             "items",
             "properties",
             "capabilities"
           ])

    # classify is fully described.
    assert schemas["ClassifyRequest"]
    assert schemas["ClassifyResponse"]
  end

  test "GET /docs renders the Swagger UI page", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)
    assert html =~ "swagger-ui"
    assert html =~ "/openapi"
  end
end
