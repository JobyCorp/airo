defmodule Airo.VoicesTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.ClientKey
  alias Airo.Voices

  @qwen_model "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
  @kokoro_model "speaches-ai/Kokoro-82M-v1.0-ONNX"

  # vLLM/Qwen exposes /audio/voices (bare strings + uploaded clones); Speaches has
  # no such endpoint — its voices ride the /models catalog as objects.
  defp stub_upstreams do
    Req.Test.stub(Airo.TestStub, fn conn ->
      case conn.request_path do
        "/v1/audio/voices" ->
          Req.Test.json(conn, %{
            "voices" => ["serena", "ryan"],
            "uploaded_voices" => [%{"name" => "my_clone"}]
          })

        "/v1/models" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => @kokoro_model,
                "task" => "text-to-speech",
                "voices" => [
                  %{"name" => "af_heart", "language" => "en-us", "gender" => "female"}
                ]
              }
            ]
          })
      end
    end)
  end

  defp speech_provider(name, adapter, url) do
    {:ok, p} =
      Config.create_provider(%{name: name, adapter_type: adapter, base_url: url, auth_kind: :none})

    p
  end

  defp speech_deployment(provider, model) do
    {:ok, d} =
      Config.create_deployment(%{provider_id: provider.id, model_name: model, capabilities: [:speech]})

    d
  end

  setup do
    qwen = speech_provider("Qwen TTS", :vllm, "http://qwen/v1")
    speaches = speech_provider("Speaches", :speaches, "http://speaches/v1")
    speech_deployment(qwen, @qwen_model)
    speech_deployment(speaches, @kokoro_model)
    stub_upstreams()
    :ok
  end

  test "aggregates voices across speech providers, tagged with model + provider" do
    voices = Voices.list(client_key: %ClientKey{allowed_aliases: ["*"]})

    by_id = Map.new(voices, &{&1["id"], &1})

    assert by_id["serena"]["model"] == @qwen_model
    assert by_id["serena"]["owned_by"] == "Qwen TTS"
    assert by_id["serena"]["object"] == "voice"
    # Uploaded clones are surfaced alongside built-ins.
    assert by_id["my_clone"]["model"] == @qwen_model
    # Speaches voices carry catalog metadata.
    assert by_id["af_heart"]["model"] == @kokoro_model
    assert by_id["af_heart"]["owned_by"] == "Speaches"
    assert by_id["af_heart"]["language"] == "en-us"
    assert by_id["af_heart"]["gender"] == "female"
  end

  test "?model restricts to one model's voices" do
    voices = Voices.list(client_key: %ClientKey{allowed_aliases: ["*"]}, model: @qwen_model)

    assert Enum.map(voices, & &1["id"]) |> Enum.sort() == ["my_clone", "ryan", "serena"]
    refute Enum.any?(voices, &(&1["model"] == @kokoro_model))
  end

  test "scopes to the client key's allowed models" do
    voices = Voices.list(client_key: %ClientKey{allowed_aliases: [@kokoro_model]})

    assert Enum.map(voices, & &1["model"]) |> Enum.uniq() == [@kokoro_model]
  end
end
