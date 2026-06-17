defmodule Airo.Adapters.Ollama do
  @moduledoc """
  Ollama adapter.

  Inference uses Ollama's OpenAI-compatible `/v1` surface via
  `Airo.Adapters.OpenAICompatible`. Local model management uses Ollama's native
  `/api/*` endpoints so the Model Shelf can inspect and pull models on a
  specific machine.
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
  def list_models(%Context{} = ctx), do: OpenAICompatible.list_models(ctx)

  @impl Airo.LocalProvider
  def catalog(%Context{} = ctx) do
    ctx
    |> native_get("/api/tags")
    |> handle_response()
    |> case do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok, Enum.map(models, &catalog_model/1)}

      {:ok, _body} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  @impl Airo.LocalProvider
  def inspect_model(model, %Context{} = ctx) when is_binary(model) do
    ctx
    |> native_post("/api/show", %{"model" => model})
    |> handle_response()
    |> case do
      {:ok, body} -> {:ok, inspect_metadata(model, body)}
      {:error, _} = error -> error
    end
  end

  @impl Airo.LocalProvider
  def pull_model(attrs, %Context{} = ctx) when is_map(attrs) do
    body =
      attrs
      |> Map.take(["model", "insecure", "username", "password"])
      |> Map.put_new("stream", false)

    ctx
    |> native_post("/api/pull", body)
    |> handle_response()
  end

  @impl Airo.LocalProvider
  def runtime_info(%Context{} = ctx) do
    version =
      case native_get(ctx, "/api/version") |> handle_response() do
        {:ok, %{"version" => version}} -> version
        _ -> nil
      end

    running =
      case native_get(ctx, "/api/ps") |> handle_response() do
        {:ok, %{"models" => models}} when is_list(models) -> Enum.map(models, &catalog_model/1)
        _ -> []
      end

    {:ok, %{version: version, running: running}}
  end

  defp catalog_model(%{"name" => name} = model) do
    details = model["details"] || %{}

    %{
      id: name,
      display_name: name,
      family: details["family"],
      families: details["families"] || [],
      format: details["format"],
      quantization: details["quantization_level"],
      size: model["size"],
      digest: model["digest"],
      parameter_size: details["parameter_size"],
      modified_at: model["modified_at"],
      raw: model
    }
  end

  defp catalog_model(%{"model" => model_name} = model),
    do: model |> Map.put("name", model_name) |> catalog_model()

  defp catalog_model(model), do: %{id: nil, display_name: nil, raw: model}

  defp inspect_metadata(model, body) do
    details = body["details"] || %{}
    model_info = body["model_info"] || %{}

    %{
      id: model,
      display_name: model,
      family: details["family"],
      families: details["families"] || [],
      format: details["format"],
      quantization: details["quantization_level"],
      parameter_size: details["parameter_size"],
      architecture: model_info["general.architecture"],
      context_window: context_window(model_info),
      modelfile: body["modelfile"],
      template: body["template"],
      parameters: body["parameters"],
      license: body["license"],
      raw: body
    }
  end

  defp context_window(model_info) do
    Enum.find_value(model_info, fn
      {key, value} when is_binary(key) ->
        if String.ends_with?(key, ".context_length"), do: value

      _ ->
        nil
    end)
  end

  defp native_get(ctx, path), do: request(ctx, :get, path)
  defp native_post(ctx, path, json), do: request(ctx, :post, path, json)

  defp request(ctx, method, path, json \\ nil) do
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

    req = Req.new(opts)
    url = ctx.provider.base_url |> native_base_url() |> Transport.full_url(path)

    case method do
      :get -> Req.get(req, url: url)
      :post -> Req.post(req, url: url, json: json)
    end
    |> normalize()
  end

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
