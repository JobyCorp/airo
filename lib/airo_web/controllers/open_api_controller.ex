defmodule AiroWeb.OpenApiController do
  @moduledoc "Serves the OpenAPI document (`GET /openapi`) as JSON."
  use AiroWeb, :controller

  def show(conn, _params) do
    json(conn, OpenApiSpex.OpenApi.to_map(AiroWeb.ApiSpec.spec()))
  end
end
