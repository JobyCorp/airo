defmodule AiroWeb.Plugs.ClientKeyAuth do
  @moduledoc """
  Authenticates a request by its Airo client key (DESIGN §10).

  Expects `Authorization: Bearer <raw-key>`. The raw key is SHA-256 hashed and
  looked up against `client_keys.hashed_key`; only an enabled key authenticates.
  On success the `Airo.Config.ClientKey` is assigned to `conn.assigns.client_key`
  (per-alias *scope* is enforced later, once the requested alias is known). On
  failure the connection is halted with a 401 OpenAI-shaped error.

  The stored value is a hash of a high-entropy key, so the equality lookup
  leaks nothing useful; no constant-time compare is required here.
  """
  import Plug.Conn

  alias Airo.Config
  alias Airo.Config.ClientKey
  alias AiroWeb.{GatewayUsage, OpenAIError}

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, raw} <- bearer_token(conn),
         %ClientKey{enabled: true} = key <-
           Config.get_client_key_by_hash(ClientKey.hash_key(raw)) do
      assign(conn, :client_key, key)
    else
      _ -> unauthorized(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    GatewayUsage.record_error(
      conn,
      GatewayUsage.capability_for_path(conn.request_path),
      :invalid_api_key,
      request_model: request_model(conn)
    )

    body =
      OpenAIError.body(
        "Invalid or missing client key.",
        "invalid_request_error",
        "invalid_api_key"
      )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
    |> halt()
  end

  defp request_model(%Plug.Conn{params: %Plug.Conn.Unfetched{}}), do: nil
  defp request_model(%Plug.Conn{params: params}) when is_map(params), do: params["model"]
  defp request_model(_conn), do: nil
end
