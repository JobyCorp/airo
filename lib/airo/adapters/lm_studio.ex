defmodule Airo.Adapters.LMStudio do
  @moduledoc """
  LM Studio adapter.

  Inference uses LM Studio's OpenAI-compatible `/v1` surface via
  `Airo.Adapters.OpenAICompatible`. Local model management uses LM Studio's
  native `/api/v1/*` REST API so the Model Shelf can inspect local inventory,
  loaded instances, quantization, context, and download state by machine.
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
    |> native_get("/api/v1/models")
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
    with {:ok, models} <- catalog(ctx),
         {:ok, model} <- find_model(models, model) do
      {:ok, inspect_metadata(model)}
    end
  end

  @impl Airo.LocalProvider
  def pull_model(attrs, %Context{} = ctx) when is_map(attrs) do
    body = Map.take(attrs, ["model", "quantization"])

    ctx
    |> native_post("/api/v1/models/download", body)
    |> handle_response()
  end

  @impl Airo.LocalProvider
  def runtime_info(%Context{} = ctx) do
    case catalog(ctx) do
      {:ok, models} -> {:ok, %{running: Enum.filter(models, &loaded?/1)}}
      {:error, _} = error -> error
    end
  end

  defp catalog_model(%{"key" => key} = model) do
    quantization = model["quantization"] || %{}
    loaded_instances = model["loaded_instances"] || []
    capabilities = model["capabilities"] || %{}

    %{
      id: key,
      display_name: model["display_name"] || key,
      family: model["architecture"] || model["publisher"],
      publisher: model["publisher"],
      type: model["type"],
      architecture: model["architecture"],
      format: model["format"],
      quantization: quantization["name"],
      bits_per_weight: quantization["bits_per_weight"],
      size: model["size_bytes"],
      parameter_size: model["params_string"],
      context_window: context_window(model),
      max_context_window: model["max_context_length"],
      loaded_instances: loaded_instances,
      capabilities: capabilities,
      vision: get_in(capabilities, ["vision"]),
      trained_for_tool_use: get_in(capabilities, ["trained_for_tool_use"]),
      reasoning: get_in(capabilities, ["reasoning"]),
      variants: model["variants"] || [],
      selected_variant: model["selected_variant"],
      description: model["description"],
      raw: model
    }
  end

  defp catalog_model(model), do: %{id: nil, display_name: nil, raw: model}

  defp inspect_metadata(model) do
    %{
      id: model.id,
      display_name: model.display_name,
      family: model.family,
      publisher: model.publisher,
      type: model.type,
      architecture: model.architecture,
      format: model.format,
      quantization: model.quantization,
      parameter_size: model.parameter_size,
      context_window: model.context_window,
      max_context_window: model.max_context_window,
      loaded_instances: model.loaded_instances,
      capabilities: model.capabilities,
      vision: model.vision,
      trained_for_tool_use: model.trained_for_tool_use,
      reasoning: model.reasoning,
      variants: model.variants,
      selected_variant: model.selected_variant,
      description: model.description,
      raw: model.raw
    }
  end

  defp find_model(models, model_id) do
    case Enum.find(models, &model_match?(&1, model_id)) do
      nil -> {:error, {:not_found, model_id}}
      model -> {:ok, model}
    end
  end

  defp model_match?(model, model_id) do
    model.id == model_id or
      model.display_name == model_id or
      model.selected_variant == model_id or
      model_id in model.variants or
      Enum.any?(model.loaded_instances, &(&1["id"] == model_id || &1[:id] == model_id))
  end

  defp loaded?(model), do: model.loaded_instances != []

  defp context_window(%{"loaded_instances" => [first | _]}) do
    get_in(first, ["config", "context_length"])
  end

  defp context_window(model), do: model["max_context_length"]

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
