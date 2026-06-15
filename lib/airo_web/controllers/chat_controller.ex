defmodule AiroWeb.ChatController do
  @moduledoc """
  OpenAI-compatible chat front door: `POST /v1/chat/completions` (DESIGN §5).

  Authentication is handled upstream by `AiroWeb.Plugs.ClientKeyAuth`; here we
  hand the request body and the authenticated client key to `Airo.Gateway` and
  translate its result into an OpenAI-shaped HTTP response. Streaming lands in S3.
  """
  use AiroWeb, :controller

  alias Airo.Gateway
  alias AiroWeb.OpenAIError

  def create(conn, params) do
    case Gateway.chat(params, conn.assigns.client_key) do
      {:ok, response} -> json(conn, response)
      {:error, reason} -> send_error(conn, reason)
    end
  end

  defp send_error(conn, :missing_model) do
    error(
      conn,
      400,
      "You must provide a `model` parameter.",
      "invalid_request_error",
      "missing_model"
    )
  end

  defp send_error(conn, {:model_not_found, model}) do
    error(
      conn,
      404,
      "The model `#{model}` does not exist or you do not have access to it.",
      "invalid_request_error",
      "model_not_found"
    )
  end

  defp send_error(conn, {:forbidden, model}) do
    error(
      conn,
      403,
      "Your client key is not authorized for model `#{model}`.",
      "invalid_request_error",
      "model_not_authorized"
    )
  end

  defp send_error(conn, :no_deployment) do
    error(
      conn,
      503,
      "No healthy deployment is available for this model.",
      "api_error",
      "no_deployment_available"
    )
  end

  defp send_error(conn, {:no_adapter, type}) do
    error(
      conn,
      502,
      "No adapter is configured for provider type `#{type}`.",
      "api_error",
      "no_adapter"
    )
  end

  defp send_error(conn, {:unsupported_capability, capability}) do
    error(
      conn,
      502,
      "The selected provider does not support `#{capability}`.",
      "api_error",
      "unsupported_capability"
    )
  end

  # Upstream returned a non-2xx. If it already spoke an OpenAI error envelope,
  # pass it through verbatim under the upstream status; otherwise wrap it.
  defp send_error(conn, {:http_error, status, %{"error" => _} = body}) do
    send_json(conn, status, body)
  end

  defp send_error(conn, {:http_error, status, _body}) do
    error(conn, status, "The upstream provider returned an error.", "api_error", "upstream_error")
  end

  defp send_error(conn, {:transport_error, _reason}) do
    error(
      conn,
      502,
      "Failed to reach the upstream provider.",
      "api_error",
      "upstream_unavailable"
    )
  end

  defp error(conn, status, message, type, code) do
    send_json(conn, status, OpenAIError.body(message, type, code))
  end

  defp send_json(conn, status, body) do
    conn
    |> put_status(status)
    |> json(body)
  end
end
