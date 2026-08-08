defmodule Airo.Adapters.Codex.OAuthTest do
  use Airo.DataCase, async: true

  alias Airo.Adapters.Codex.OAuth
  alias Airo.Config
  alias Airo.Config.Provider

  defp jwt(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    header <> "." <> payload <> ".sig"
  end

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

  test "refreshes form-encoded and persists when the token is expired" do
    past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)
    provider = provider_with(%{value: "old-token", refresh_token: "refresh-1", expires_at: past})

    Req.Test.stub(Airo.TestStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      sent = URI.decode_query(raw)

      assert sent["grant_type"] == "refresh_token"
      assert sent["refresh_token"] == "refresh-1"
      assert sent["client_id"] == OAuth.client_id()

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

  test "falls back to the JWT exp claim when the refresh omits expires_in" do
    past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)
    provider = provider_with(%{value: "old-token", refresh_token: "refresh-1", expires_at: past})

    exp = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.to_unix()
    token = jwt(%{"exp" => exp})

    Req.Test.stub(Airo.TestStub, fn conn ->
      Req.Test.json(conn, %{"access_token" => token})
    end)

    assert OAuth.ensure_fresh(provider) == {:ok, token}

    reloaded = Config.get_secret!(provider.credential_id)
    assert DateTime.to_unix(reloaded.expires_at) == exp
  end

  test "errors when there is no credential" do
    assert OAuth.ensure_fresh(%Provider{auth_kind: :oauth, credential: nil}) ==
             {:error, :no_credential}
  end

  describe "account_id/1" do
    test "extracts the chatgpt account id from the auth claim" do
      token = jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_123"}})
      assert OAuth.account_id(token) == {:ok, "acct_123"}
    end

    test "errors on tokens without the claim" do
      assert OAuth.account_id(jwt(%{"sub" => "user"})) == {:error, :no_account_id}
      assert OAuth.account_id("not-a-jwt") == {:error, :no_account_id}
    end
  end
end
