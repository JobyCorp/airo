defmodule AiroWeb.Plugs.ClientKeyAuthTest do
  use AiroWeb.ConnCase, async: true

  alias Airo.Config
  alias AiroWeb.Plugs.ClientKeyAuth

  defp call(conn), do: ClientKeyAuth.call(conn, ClientKeyAuth.init([]))

  defp mint(opts \\ []) do
    {:ok, key} =
      Config.mint_client_key(%{
        name: "k-#{System.unique_integer([:positive])}",
        allowed_aliases: Keyword.get(opts, :allowed_aliases, ["*"]),
        enabled: Keyword.get(opts, :enabled, true)
      })

    key
  end

  test "assigns the client key for a valid bearer token", %{conn: conn} do
    key = mint()
    conn = conn |> put_req_header("authorization", "Bearer " <> key.key) |> call()

    refute conn.halted
    assert conn.assigns.client_key.id == key.id
  end

  test "401s when the authorization header is missing", %{conn: conn} do
    conn = call(conn)
    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_api_key"
  end

  test "401s for an unknown key", %{conn: conn} do
    conn = conn |> put_req_header("authorization", "Bearer airo_nope") |> call()
    assert conn.status == 401
  end

  test "401s for a disabled key", %{conn: conn} do
    key = mint(enabled: false)
    conn = conn |> put_req_header("authorization", "Bearer " <> key.key) |> call()
    assert conn.status == 401
  end
end
