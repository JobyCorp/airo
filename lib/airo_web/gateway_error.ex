defmodule AiroWeb.GatewayError do
  @moduledoc """
  Maps `Airo.Gateway` error tuples to OpenAI-shaped HTTP responses, shared by
  every gateway controller (chat, embeddings, rerank, audio). When an upstream
  already spoke an OpenAI error envelope, it is passed through under the upstream
  status; otherwise a gateway envelope is synthesized.
  """
  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias AiroWeb.OpenAIError

  @doc "Render `reason` (an `Airo.Gateway.error`) onto `conn`."
  def send_error(conn, reason) do
    {status, body} = response(reason)

    conn
    |> put_status(status)
    |> json(body)
  end

  @doc "Map a gateway error reason to `{http_status, OpenAI-shaped body}`."
  def response(reason), do: to_response(reason)

  @doc "The OpenAI-compatible error code for a gateway error reason."
  def code(reason) do
    {_status, body} = response(reason)
    get_in(body, ["error", "code"])
  end

  @doc "The upstream HTTP status embedded in a gateway error reason, if any."
  def upstream_status({:http_error, status, _body}), do: status
  def upstream_status(_reason), do: nil

  # Upstream error already in OpenAI shape → pass through verbatim.
  defp to_response({:http_error, status, %{"error" => _} = body}), do: {status, body}

  defp to_response({:http_error, status, _body}),
    do:
      {status,
       OpenAIError.body("The upstream provider returned an error.", "api_error", "upstream_error")}

  defp to_response({:transport_error, _reason}),
    do:
      {502,
       OpenAIError.body(
         "Failed to reach the upstream provider.",
         "api_error",
         "upstream_unavailable"
       )}

  defp to_response(:invalid_api_key),
    do:
      {401,
       OpenAIError.body(
         "Invalid or missing client key.",
         "invalid_request_error",
         "invalid_api_key"
       )}

  defp to_response(:missing_model),
    do:
      {400,
       OpenAIError.body(
         "You must provide a `model` parameter.",
         "invalid_request_error",
         "missing_model"
       )}

  defp to_response({:model_not_found, model}),
    do:
      {404,
       OpenAIError.body(
         "The model `#{model}` does not exist or you do not have access to it.",
         "invalid_request_error",
         "model_not_found"
       )}

  defp to_response({:forbidden, model}),
    do:
      {403,
       OpenAIError.body(
         "Your client key is not authorized for model `#{model}`.",
         "invalid_request_error",
         "model_not_authorized"
       )}

  defp to_response(:no_deployment),
    do:
      {503,
       OpenAIError.body(
         "No healthy deployment is available for this model.",
         "api_error",
         "no_deployment_available"
       )}

  defp to_response(:selected_binding_unavailable),
    do:
      {409,
       OpenAIError.body(
         "The pinned deployment (route.binding) is not an available candidate for this model.",
         "invalid_request_error",
         "selected_binding_unavailable"
       )}

  defp to_response({:no_adapter, type}),
    do:
      {502,
       OpenAIError.body(
         "No adapter is configured for provider type `#{type}`.",
         "api_error",
         "no_adapter"
       )}

  defp to_response({:unsupported_capability, capability}),
    do:
      {502,
       OpenAIError.body(
         "The selected provider does not support `#{capability}`.",
         "api_error",
         "unsupported_capability"
       )}

  defp to_response({:unsupported_intent, intent}),
    do:
      {400,
       OpenAIError.body(
         "Unsupported realtime intent `#{intent}`.",
         "invalid_request_error",
         "unsupported_intent"
       )}
end
