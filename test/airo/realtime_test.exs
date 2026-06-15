defmodule Airo.RealtimeTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Realtime

  defp provider(base_url, opts \\ []) do
    {:ok, p} =
      Config.create_provider(%{
        name: "p-#{System.unique_integer([:positive])}",
        adapter_type: :speaches,
        base_url: base_url,
        auth_kind: Keyword.get(opts, :auth_kind, :none)
      })

    p
  end

  defp deployment(provider, model) do
    {:ok, d} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: model,
        capability: :transcription
      })

    d
  end

  defp key(allowed \\ ["*"]) do
    {:ok, k} =
      Config.mint_client_key(%{
        name: "k-#{System.unique_integer([:positive])}",
        allowed_aliases: allowed
      })

    k
  end

  test "resolves a concrete model to an upstream wss target" do
    p = provider("https://speaches.local/v1")
    deployment(p, "faster-whisper")

    assert {:ok, target} = Realtime.resolve("faster-whisper", key(), "transcription")
    assert target.ws_scheme == :wss
    assert target.host == "speaches.local"
    assert target.port == 443
    assert target.path =~ "/v1/realtime"
    assert target.path =~ "model=faster-whisper"
    assert target.path =~ "intent=transcription"
    assert target.deployment.model_name == "faster-whisper"
    assert target.headers == []
  end

  test "uses ws:// and the explicit port for an http base_url, with bearer auth" do
    {:ok, secret} =
      Config.create_secret(%{
        name: "s-#{System.unique_integer([:positive])}",
        kind: :api_key,
        value: "sk-up"
      })

    p = provider("http://speaches.local:8000/v1", auth_kind: :api_key)
    {:ok, p} = Config.update_provider(p, %{credential_id: secret.id})
    deployment(p, "whisper")

    assert {:ok, target} = Realtime.resolve("whisper", key(), "transcription")
    assert target.ws_scheme == :ws
    assert target.port == 8000
    assert target.headers == [{"authorization", "Bearer sk-up"}]
  end

  test "resolves an alias to its candidate deployment" do
    p = provider("https://speaches.local/v1")
    d = deployment(p, "faster-whisper")

    {:ok, _alias} =
      Config.create_alias(%{
        name: "stt",
        capability: :transcription,
        strategy: :priority,
        candidates: [%{deployment_id: d.id, weight: 100, priority: 0}]
      })

    assert {:ok, target} = Realtime.resolve("stt", key(), "transcription")
    assert target.deployment.model_name == "faster-whisper"
  end

  test "errors: forbidden, unknown model, unsupported intent" do
    p = provider("https://speaches.local/v1")
    deployment(p, "whisper")

    assert {:error, {:forbidden, "whisper"}} =
             Realtime.resolve("whisper", key(["other"]), "transcription")

    assert {:error, {:model_not_found, "ghost"}} =
             Realtime.resolve("ghost", key(), "transcription")

    assert {:error, {:unsupported_intent, "voice"}} = Realtime.resolve("whisper", key(), "voice")
  end
end
