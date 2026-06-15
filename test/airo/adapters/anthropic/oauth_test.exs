defmodule Airo.Adapters.Anthropic.OAuthTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.Provider
  alias Airo.Adapters.Anthropic.OAuth

  defp provider_with(secret_attrs) do
    {:ok, secret} =
      Config.create_secret(
        Map.merge(%{name: "s-#{System.unique_integer([:positive])}", kind: :oauth}, secret_attrs)
      )

    %Provider{auth_kind: :oauth, credential_id: secret.id, credential: secret}
  end

  test "returns the current token when it is still fresh" do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    provider = provider_with(%{value: "fresh-token", expires_at: future})

    assert OAuth.ensure_fresh(provider) == {:ok, "fresh-token"}
  end

  test "refreshes and persists when the token is expired" do
    past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)
    provider = provider_with(%{value: "old-token", refresh_token: "refresh-1", expires_at: past})

    Req.Test.stub(Airo.TestStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw)["grant_type"] == "refresh_token"

      Req.Test.json(conn, %{
        "access_token" => "new-token",
        "refresh_token" => "refresh-2",
        "expires_in" => 3600
      })
    end)

    assert OAuth.ensure_fresh(provider) == {:ok, "new-token"}

    reloaded = Config.get_secret!(provider.credential_id)
    assert reloaded.value == "new-token"
    assert reloaded.refresh_token == "refresh-2"
    assert DateTime.compare(reloaded.expires_at, DateTime.utc_now()) == :gt
  end

  test "errors when there is no credential" do
    assert OAuth.ensure_fresh(%Provider{auth_kind: :oauth, credential: nil}) ==
             {:error, :no_credential}
  end
end
