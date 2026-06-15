defmodule Airo.Adapters.OpenAICompatible do
  @moduledoc """
  Adapter for genuinely OpenAI-compatible upstreams — vLLM, Ollama, LM Studio,
  OpenAI itself, and Speaches' audio endpoints (DESIGN §6). The request is
  already in canonical (OpenAI) shape, so this is near-passthrough: forward the
  body to the provider's endpoint and hand back the decoded response.

  Implements `chat/2` (non-streaming) and `stream/4`. Since these upstreams
  already emit OpenAI-shaped SSE deltas, streaming is near-passthrough — the
  Transport parses the SSE and we forward each chunk unchanged. The remaining
  capabilities land in later sprints.
  """
  @behaviour Airo.Adapter

  alias Airo.Adapter.Context
  alias Airo.Config.Deployment
  alias Airo.Transport

  @impl Airo.Adapter
  def chat(params, %Context{} = ctx) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> then(&Transport.post(ctx, "/chat/completions", &1))
    |> handle_response()
  end

  @impl Airo.Adapter
  def stream(params, %Context{} = ctx, acc, reducer) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> Map.put("stream", true)
    |> then(&Transport.stream(ctx, "/chat/completions", &1, acc, reducer))
  end

  @impl Airo.Adapter
  def embed(params, %Context{} = ctx) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> then(&Transport.post(ctx, "/embeddings", &1))
    |> handle_response()
  end

  # Text-to-speech: JSON in, binary audio out (Speaches `/v1/audio/speech`).
  @impl Airo.Adapter
  def speech(params, %Context{} = ctx) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> then(&Transport.post(ctx, "/audio/speech", &1))
    |> handle_audio()
  end

  # Transcription: a multipart upload (`file` + `model`) in, JSON out.
  @impl Airo.Adapter
  def transcribe(params, %Context{} = ctx) when is_map(params) do
    case multipart_parts(params, ctx.deployment) do
      {:ok, parts} ->
        ctx |> Transport.post_multipart("/audio/transcriptions", parts) |> handle_response()

      {:error, _} = error ->
        error
    end
  end

  # Req's multipart part names must be atoms; whitelist the OpenAI transcription
  # fields rather than converting arbitrary client keys to atoms.
  @transcription_fields %{
    "language" => :language,
    "prompt" => :prompt,
    "response_format" => :response_format,
    "temperature" => :temperature
  }

  defp multipart_parts(params, deployment) do
    case params["file"] do
      %Plug.Upload{path: path, filename: filename, content_type: content_type} ->
        file =
          {File.read!(path),
           filename: filename, content_type: content_type || "application/octet-stream"}

        extra =
          for {key, atom} <- @transcription_fields,
              (value = params[key]) != nil,
              do: {atom, to_string(value)}

        {:ok, [{:model, upstream_model(deployment, params)}, {:file, file} | extra]}

      _ ->
        {:error, {:invalid_request, :missing_file}}
    end
  end

  defp upstream_model(%Deployment{model_name: model}, _params) when is_binary(model), do: model
  defp upstream_model(_deployment, params), do: params["model"]

  defp handle_audio({:ok, %{status: status, body: body, headers: headers}})
       when status in 200..299 do
    {:ok, {:audio, content_type(headers), body}}
  end

  defp handle_audio({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_audio({:error, reason}), do: {:error, {:transport_error, reason}}

  defp content_type(headers) do
    case headers["content-type"] do
      [type | _] -> type
      _ -> "application/octet-stream"
    end
  end

  # When routing has chosen a concrete deployment, the upstream model is the
  # deployment's model_name — override whatever logical alias the client sent.
  defp put_model(params, %Deployment{model_name: model}) when is_binary(model),
    do: Map.put(params, "model", model)

  defp put_model(params, _), do: params

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}), do: {:error, {:transport_error, reason}}
end
