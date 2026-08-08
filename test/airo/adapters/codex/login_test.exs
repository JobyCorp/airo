defmodule Airo.Adapters.Codex.LoginTest do
  use ExUnit.Case, async: true

  alias Airo.Adapters.Codex.{Login, OAuth}

  describe "start/0" do
    test "builds a PKCE authorize URL bound to the returned verifier" do
      %{url: url, verifier: verifier, state: state} = Login.start()

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert uri.host == "auth.openai.com"
      assert uri.path == "/oauth/authorize"
      assert query["response_type"] == "code"
      assert query["client_id"] == OAuth.client_id()
      assert query["redirect_uri"] == "http://localhost:1455/auth/callback"
      assert query["scope"] == "openid profile email offline_access"
      assert query["code_challenge_method"] == "S256"
      assert query["state"] == state

      expected =
        :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

      assert query["code_challenge"] == expected
    end
  end

  describe "exchange/2" do
    test "extracts the code from a pasted callback URL and posts the PKCE exchange" do
      test_pid = self()

      Req.Test.stub(Airo.TestStub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:req, URI.decode_query(raw)})

        Req.Test.json(conn, %{
          "access_token" => "access-1",
          "refresh_token" => "refresh-1",
          "expires_in" => 3600
        })
      end)

      callback = "http://localhost:1455/auth/callback?code=abc123&state=xyz"

      assert {:ok, tokens} = Login.exchange(callback, "verifier-1")
      assert tokens.value == "access-1"
      assert tokens.refresh_token == "refresh-1"
      assert DateTime.compare(tokens.expires_at, DateTime.utc_now()) == :gt

      assert_received {:req, sent}
      assert sent["grant_type"] == "authorization_code"
      assert sent["code"] == "abc123"
      assert sent["code_verifier"] == "verifier-1"
      assert sent["redirect_uri"] == "http://localhost:1455/auth/callback"
    end

    test "accepts a bare code" do
      Req.Test.stub(Airo.TestStub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(raw)["code"] == "bare-code"
        Req.Test.json(conn, %{"access_token" => "access-2"})
      end)

      assert {:ok, %{value: "access-2"}} = Login.exchange("  bare-code  ", "verifier-2")
    end

    test "rejects input without a code" do
      assert Login.exchange("http://localhost:1455/auth/callback?error=denied", "v") ==
               {:error, :no_code}

      assert Login.exchange("", "v") == {:error, :no_code}
    end

    test "surfaces a failed exchange" do
      Req.Test.stub(Airo.TestStub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, {:oauth_exchange_failed, 400, %{"error" => "invalid_grant"}}} =
               Login.exchange("code-x", "v")
    end
  end
end
