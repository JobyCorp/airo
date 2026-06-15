defmodule AiroWeb.AudioControllerTest do
  use AiroWeb.ConnCase, async: true

  alias Airo.Config

  defp seed_alias(name, model, capability) do
    {:ok, provider} =
      Config.create_provider(%{
        name: "sp-#{System.unique_integer([:positive])}",
        adapter_type: :speaches,
        base_url: "http://speaches:8000/v1",
        auth_kind: :none
      })

    {:ok, deployment} =
      Config.create_deployment(%{
        provider_id: provider.id,
        model_name: model,
        capability: capability
      })

    {:ok, _} =
      Config.create_alias(%{
        name: name,
        capability: capability,
        strategy: :priority,
        candidates: [%{deployment_id: deployment.id, weight: 100, priority: 0}]
      })

    :ok
  end

  defp mint,
    do:
      elem(
        Config.mint_client_key(%{
          name: "k-#{System.unique_integer([:positive])}",
          allowed_aliases: ["*"]
        }),
        1
      ).key

  defp authed(conn, key), do: put_req_header(conn, "authorization", "Bearer " <> key)

  test "POST /v1/audio/speech returns binary audio with the upstream content type", %{conn: conn} do
    seed_alias("tts-std", "tts-1", :speech)

    Req.Test.stub(Airo.TestStub, fn upstream ->
      upstream
      |> Plug.Conn.put_resp_content_type("audio/mpeg", nil)
      |> Plug.Conn.send_resp(200, <<9, 9, 9>>)
    end)

    conn =
      conn
      |> authed(mint())
      |> post(~p"/v1/audio/speech", %{
        "model" => "tts-std",
        "input" => "hello",
        "voice" => "alloy"
      })

    assert response(conn, 200) == <<9, 9, 9>>
    assert ["audio/mpeg"] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "x-gateway-model") == ["tts-1"]
  end

  test "POST /v1/audio/transcriptions forwards the upload and returns the transcript", %{
    conn: conn
  } do
    seed_alias("transcribe-std", "whisper-1", :transcription)

    Req.Test.stub(Airo.TestStub, fn upstream ->
      assert ["multipart/form-data" <> _] = Plug.Conn.get_req_header(upstream, "content-type")
      Req.Test.json(upstream, %{"text" => "transcribed text"})
    end)

    path = Path.join(System.tmp_dir!(), "airo-ctrl-#{System.unique_integer([:positive])}.wav")
    File.write!(path, "RIFFfake")
    upload = %Plug.Upload{path: path, filename: "a.wav", content_type: "audio/wav"}

    conn =
      conn
      |> authed(mint())
      |> post(~p"/v1/audio/transcriptions", %{"model" => "transcribe-std", "file" => upload})

    assert json_response(conn, 200)["text"] == "transcribed text"
    File.rm(path)
  end
end
