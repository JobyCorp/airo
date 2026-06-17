defmodule Airo.Adapters.SpeachesTest do
  use ExUnit.Case, async: true

  alias Airo.Adapter.Context
  alias Airo.Adapters.Speaches
  alias Airo.Config.{Deployment, Provider}

  defp context(stub, fields \\ []) do
    provider =
      struct(
        %Provider{
          name: "speaches-mini",
          adapter_type: :speaches,
          base_url: "http://speaches:8000/v1",
          auth_kind: :none
        },
        Keyword.get(fields, :provider, [])
      )

    Context.new(provider,
      deployment: fields[:deployment],
      opts: [req_options: [plug: {Req.Test, stub}]]
    )
  end

  defp models_payload do
    %{
      "data" => [
        tts_model(),
        %{
          "id" => "Systran/faster-whisper-large-v3",
          "created" => 1_778_979_762,
          "object" => "model",
          "owned_by" => "Systran",
          "language" => ["en", "es", "fr"],
          "task" => "automatic-speech-recognition"
        }
      ],
      "object" => "list"
    }
  end

  defp tts_model do
    %{
      "id" => "speaches-ai/Kokoro-82M-v1.0-ONNX",
      "created" => 1_778_979_749,
      "object" => "model",
      "owned_by" => "speaches-ai",
      "language" => ["multilingual"],
      "task" => "text-to-speech",
      "sample_rate" => 24_000,
      "voices" => [
        %{"name" => "af_heart", "language" => "en-us", "gender" => "female"},
        %{"name" => "am_echo", "language" => "en-us", "gender" => "male"},
        %{"name" => "jf_alpha", "language" => "ja", "gender" => "female"}
      ]
    }
  end

  describe "inference delegation" do
    test "speech still uses the OpenAI-compatible /v1 audio surface" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_header("content-type", "audio/mpeg")
        |> Plug.Conn.resp(200, "audio")
      end)

      ctx =
        context(__MODULE__,
          deployment: %Deployment{model_name: "speaches-ai/Kokoro-82M-v1.0-ONNX"}
        )

      assert {:ok, {:audio, "audio/mpeg", "audio"}} =
               Speaches.speech(%{"model" => "tts", "input" => "hi", "voice" => "af_heart"}, ctx)

      assert_received {:request, "/v1/audio/speech",
                       %{"model" => "speaches-ai/Kokoro-82M-v1.0-ONNX"}}
    end
  end

  describe "catalog/1" do
    test "uses /v1/models and normalizes audio model metadata" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})
        Req.Test.json(conn, models_payload())
      end)

      assert {:ok, [tts, asr]} = Speaches.catalog(context(__MODULE__))
      assert tts.id == "speaches-ai/Kokoro-82M-v1.0-ONNX"
      assert tts.type == "speech"
      assert tts.sample_rate == 24_000
      assert tts.voice_count == 3
      assert tts.voice_languages == ["en-us", "ja"]
      assert asr.type == "transcription"
      assert asr.language_count == 3
      assert_received {:request, "GET", "/v1/models"}
    end
  end

  describe "inspect_model/2" do
    test "uses /v1/models/:id and returns detailed metadata" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.request_path})
        Req.Test.json(conn, tts_model())
      end)

      assert {:ok, metadata} =
               Speaches.inspect_model("speaches-ai/Kokoro-82M-v1.0-ONNX", context(__MODULE__))

      assert metadata.type == "speech"
      assert metadata.voice_count == 3
      assert_received {:request, "/v1/models/speaches-ai%2FKokoro-82M-v1.0-ONNX"}
    end
  end

  describe "runtime_info/1" do
    test "reads experimental /api/ps loaded model state" do
      Req.Test.stub(__MODULE__, fn
        %{request_path: "/api/ps"} = conn ->
          Req.Test.json(conn, %{"models" => ["speaches-ai/Kokoro-82M-v1.0-ONNX"]})
      end)

      assert {:ok, %{running: [running]}} = Speaches.runtime_info(context(__MODULE__))
      assert running.id == "speaches-ai/Kokoro-82M-v1.0-ONNX"
    end
  end
end
