defmodule Airo.TransportTest do
  use ExUnit.Case, async: true

  alias Airo.Config.{Provider, Secret}
  alias Airo.Transport

  describe "full_url/2" do
    test "preserves a base path prefix like /v1" do
      assert Transport.full_url("http://h:8000/v1", "/chat/completions") ==
               "http://h:8000/v1/chat/completions"
    end

    test "tolerates a trailing slash on base and a missing slash on path" do
      assert Transport.full_url("http://h/v1/", "chat/completions") ==
               "http://h/v1/chat/completions"
    end

    test "works for a bare-host base" do
      assert Transport.full_url("http://h:11434", "/v1/embeddings") ==
               "http://h:11434/v1/embeddings"
    end
  end

  describe "auth_headers/1" do
    test "none → no header" do
      assert Transport.auth_headers(%Provider{auth_kind: :none}) == []
    end

    test "api_key → Bearer from the preloaded credential" do
      provider = %Provider{
        auth_kind: :api_key,
        credential_id: 1,
        credential: %Secret{value: "sk-x"}
      }

      assert Transport.auth_headers(provider) == [{"authorization", "Bearer sk-x"}]
    end

    test "oauth → Bearer from the credential access token" do
      provider = %Provider{auth_kind: :oauth, credential_id: 1, credential: %Secret{value: "tok"}}
      assert Transport.auth_headers(provider) == [{"authorization", "Bearer tok"}]
    end
  end

  describe "finch_pools/0" do
    test "defaults to a single default pool" do
      assert %{default: opts} = Transport.finch_pools()
      assert Keyword.has_key?(opts, :size)
    end
  end
end
