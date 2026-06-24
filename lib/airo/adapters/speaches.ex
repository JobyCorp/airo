defmodule Airo.Adapters.Speaches do
  @moduledoc """
  Speaches adapter.

  Speech and transcription requests use Speaches' OpenAI-compatible `/v1`
  surface via `Airo.Adapters.OpenAICompatible`. Local metadata sync uses
  Speaches' model inventory and runtime endpoints so the Model Shelf can show
  audio-specific model posture.
  """
  @behaviour Airo.Adapter
  @behaviour Airo.LocalProvider

  alias Airo.Adapter.Context
  alias Airo.Adapters.OpenAICompatible
  alias Airo.Transport

  @impl Airo.Adapter
  def chat(params, %Context{} = ctx), do: OpenAICompatible.chat(params, ctx)

  @impl Airo.Adapter
  def stream(params, %Context{} = ctx, acc, reducer),
    do: OpenAICompatible.stream(params, ctx, acc, reducer)

  @impl Airo.Adapter
  def embed(params, %Context{} = ctx), do: OpenAICompatible.embed(params, ctx)

  @impl Airo.Adapter
  def speech(params, %Context{} = ctx), do: OpenAICompatible.speech(params, ctx)

  @impl Airo.Adapter
  def transcribe(params, %Context{} = ctx), do: OpenAICompatible.transcribe(params, ctx)

  @impl Airo.Adapter
  def list_models(%Context{} = ctx), do: OpenAICompatible.list_models(ctx)

  # Speaches has no `/audio/voices`; voices ride the model catalog. Return the
  # deployment model's voices (Kokoro carries name/language/gender per voice).
  @impl Airo.Adapter
  def voices(%Context{deployment: %{model_name: model}} = ctx) when is_binary(model) do
    with {:ok, models} <- catalog(ctx) do
      case Enum.find(models, &(&1.id == model)) do
        %{voices: voices} when is_list(voices) -> {:ok, Enum.flat_map(voices, &normalize_voice/1)}
        _ -> {:ok, []}
      end
    end
  end

  def voices(%Context{}), do: {:ok, []}

  defp normalize_voice(%{"name" => name} = v) when is_binary(name),
    do: [reject_nil(%{id: name, language: v["language"], gender: v["gender"]})]

  defp normalize_voice(name) when is_binary(name), do: [%{id: name}]
  defp normalize_voice(_), do: []

  defp reject_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  @impl Airo.LocalProvider
  def catalog(%Context{} = ctx) do
    ctx
    |> openai_get("/models")
    |> handle_response()
    |> case do
      {:ok, %{"data" => models}} when is_list(models) ->
        {:ok, Enum.map(models, &catalog_model/1)}

      {:ok, _body} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  @impl Airo.LocalProvider
  def inspect_model(model, %Context{} = ctx) when is_binary(model) do
    with {:ok, body} <- get_model(ctx, model) do
      {:ok, catalog_model(body)}
    else
      {:error, {:http_error, 404, _body}} ->
        with {:ok, models} <- catalog(ctx),
             {:ok, model} <- find_model(models, model) do
          {:ok, model}
        end

      {:error, _} = error ->
        error
    end
  end

  @impl Airo.LocalProvider
  def runtime_info(%Context{} = ctx) do
    running =
      case native_get(ctx, "/api/ps") |> handle_response() do
        {:ok, %{"models" => models}} when is_list(models) ->
          Enum.map(models, &running_model/1)

        {:ok, running} when is_map(running) ->
          running
          |> Enum.flat_map(fn {task, models} ->
            Enum.map(models || [], &running_model(&1, task))
          end)

        _ ->
          []
      end

    {:ok, %{running: running}}
  end

  defp get_model(ctx, model_id) do
    path = "/models/" <> URI.encode(model_id, &URI.char_unreserved?/1)

    ctx
    |> openai_get(path)
    |> handle_response()
  end

  defp catalog_model(%{"id" => id} = model) do
    voices = model["voices"] || []
    languages = model["language"] || []
    task = model["task"]

    %{
      id: id,
      display_name: id,
      family: family(id),
      type: task_type(task),
      task: task,
      owned_by: model["owned_by"],
      created: model["created"],
      languages: languages,
      language_count: length(languages),
      sample_rate: model["sample_rate"],
      voices: voices,
      voice_count: length(voices),
      voice_languages: voice_languages(voices),
      raw: model
    }
  end

  defp catalog_model(model), do: %{id: nil, display_name: nil, raw: model}

  defp find_model(models, model_id) do
    case Enum.find(models, &(&1.id == model_id || &1.display_name == model_id)) do
      nil -> {:error, {:not_found, model_id}}
      model -> {:ok, model}
    end
  end

  defp running_model(model, task \\ nil)

  defp running_model(model_id, task) when is_binary(model_id) do
    %{id: model_id, display_name: model_id, task: task}
  end

  defp running_model(%{"id" => id} = model, task) do
    catalog_model(Map.put_new(model, "task", task) |> Map.put_new("id", id))
  end

  defp running_model(model, task), do: %{id: nil, task: task, raw: model}

  defp family(model_id) do
    model_id
    |> Path.basename()
    |> String.split(["-", "_"], trim: true)
    |> List.first()
    |> case do
      nil -> nil
      family -> String.downcase(family)
    end
  end

  defp task_type("text-to-speech"), do: "speech"
  defp task_type("automatic-speech-recognition"), do: "transcription"
  defp task_type(task), do: task

  defp voice_languages(voices) do
    voices
    |> Enum.map(& &1["language"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp openai_get(ctx, path), do: request(ctx, openai_base_url(ctx.provider.base_url), path)
  defp native_get(ctx, path), do: request(ctx, native_base_url(ctx.provider.base_url), path)

  defp request(ctx, base_url, path) do
    opts =
      [
        finch: Airo.Finch,
        headers: Transport.auth_headers(ctx.provider),
        receive_timeout: 30_000,
        retry: false,
        decode_json: [keys: :strings]
      ]
      |> Keyword.merge(global_req_options())
      |> Keyword.merge(Keyword.get(ctx.opts, :req_options, []))

    Req.new(opts)
    |> Req.get(url: Transport.full_url(base_url, path))
    |> normalize()
  end

  defp openai_base_url(base_url), do: String.trim_trailing(base_url, "/")

  defp native_base_url(base_url) do
    base_url
    |> String.trim_trailing("/")
    |> String.replace(~r{/v1$}, "")
  end

  defp normalize({:ok, %Req.Response{status: status, body: body, headers: headers}}) do
    {:ok, %{status: status, body: body, headers: Map.new(headers)}}
  end

  defp normalize({:error, reason}), do: {:error, reason}

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp global_req_options do
    Application.get_env(:airo, Airo.Transport, []) |> Keyword.get(:req_options, [])
  end
end
