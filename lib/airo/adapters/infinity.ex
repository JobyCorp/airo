defmodule Airo.Adapters.Infinity do
  @moduledoc """
  Adapter for [Infinity](https://github.com/michaelfeil/infinity) — an
  embeddings + rerank + classify server (DESIGN §6). Embeddings are
  OpenAI-compatible (`/embeddings`); rerank uses the de-facto Jina/Cohere
  `/rerank` shape (Airo exposes it at `/v1/rerank`); classify uses Infinity's
  `/classify` (`{model, input}` → scored labels), exposed at `/v1/classify`.
  All are near-passthrough.
  """
  @behaviour Airo.Adapter
  @behaviour Airo.LocalProvider

  alias Airo.Adapter.Context
  alias Airo.Config.Deployment
  alias Airo.Transport

  @metric_names [
    "http_requests_total",
    "http_request_duration_seconds_count",
    "http_request_duration_seconds_sum"
  ]

  @impl Airo.Adapter
  def embed(params, %Context{} = ctx) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> then(&Transport.post(ctx, "/embeddings", &1))
    |> handle_response()
  end

  @impl Airo.Adapter
  def rerank(params, %Context{} = ctx) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> then(&Transport.post(ctx, "/rerank", &1))
    |> handle_response()
  end

  @impl Airo.Adapter
  def classify(params, %Context{} = ctx) when is_map(params) do
    params
    |> put_model(ctx.deployment)
    |> then(&Transport.post(ctx, "/classify", &1))
    |> handle_response()
  end

  @impl Airo.Adapter
  def list_models(%Context{} = ctx) do
    ctx |> Transport.get("/models") |> handle_response() |> to_model_ids()
  end

  @impl Airo.LocalProvider
  def catalog(%Context{} = ctx) do
    ctx
    |> Transport.get("/models")
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
    with {:ok, models} <- catalog(ctx),
         {:ok, model} <- find_model(models, model) do
      {:ok, inspect_metadata(model)}
    end
  end

  @impl Airo.LocalProvider
  def runtime_info(%Context{} = ctx) do
    running =
      case catalog(ctx) do
        {:ok, models} -> models
        {:error, _reason} -> []
      end

    metrics =
      case metrics(ctx) do
        {:ok, metrics} -> metrics
        {:error, _reason} -> %{}
      end

    {:ok, %{running: running, metrics: metrics}}
  end

  defp catalog_model(%{"id" => id} = model) do
    capabilities = model["capabilities"] || []
    stats = model["stats"] || %{}

    %{
      id: id,
      display_name: id,
      family: family(id),
      type: infinity_type(capabilities),
      owned_by: model["owned_by"],
      created: model["created"],
      backend: model["backend"],
      capabilities: capabilities,
      stats: stats,
      queue_fraction: stats["queue_fraction"],
      queue_absolute: stats["queue_absolute"],
      results_pending: stats["results_pending"],
      batch_size: stats["batch_size"],
      raw: model
    }
  end

  defp catalog_model(model), do: %{id: nil, display_name: nil, raw: model}

  defp inspect_metadata(model) do
    %{
      id: model.id,
      display_name: model.display_name,
      family: model.family,
      type: model.type,
      owned_by: model.owned_by,
      created: model.created,
      backend: model.backend,
      capabilities: model.capabilities,
      stats: model.stats,
      queue_fraction: model.queue_fraction,
      queue_absolute: model.queue_absolute,
      results_pending: model.results_pending,
      batch_size: model.batch_size,
      raw: model.raw
    }
  end

  defp find_model(models, model_id) do
    case Enum.find(models, &(&1.id == model_id || &1.display_name == model_id)) do
      nil -> {:error, {:not_found, model_id}}
      model -> {:ok, model}
    end
  end

  defp metrics(ctx) do
    ctx
    |> request_text("/metrics")
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, parse_metrics(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp parse_metrics(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      with false <- String.starts_with?(line, "#"),
           [sample, value] <- String.split(line, ~r/\s+/, parts: 2),
           {:ok, name, labels} <- parse_sample(sample),
           true <- name in @metric_names,
           {number, _rest} <- Float.parse(value) do
        put_metric(acc, name, labels, number)
      else
        _ -> acc
      end
    end)
  end

  defp parse_sample(sample) do
    case Regex.run(~r/^([^\{]+)(?:\{(.+)\})?$/, sample) do
      [_match, name] -> {:ok, name, %{}}
      [_match, name, labels] -> {:ok, name, parse_labels(labels)}
      _ -> :error
    end
  end

  defp parse_labels(labels) do
    ~r/([^=,]+)="([^"]*)"/
    |> Regex.scan(labels)
    |> Map.new(fn [_match, key, value] -> {key, value} end)
  end

  defp put_metric(acc, name, %{"handler" => handler} = labels, value) do
    handler = String.trim_leading(handler, "/")
    metric = String.replace(name, "http_", "")
    key = metric_key(metric, labels)

    Map.update(acc, handler, %{key => value}, &Map.put(&1, key, value))
  end

  defp put_metric(acc, _name, _labels, _value), do: acc

  defp metric_key("requests_total", %{"method" => method, "status" => status}) do
    "requests_#{String.downcase(method)}_#{status}"
  end

  defp metric_key("request_duration_seconds_count", %{"method" => method}),
    do: "duration_#{String.downcase(method)}_count"

  defp metric_key("request_duration_seconds_sum", %{"method" => method}),
    do: "duration_#{String.downcase(method)}_seconds_sum"

  defp metric_key(name, _labels), do: name

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

  defp infinity_type(capabilities) do
    cond do
      "rerank" in capabilities -> "rerank"
      "classify" in capabilities -> "classify"
      "image_embed" in capabilities -> "image_embed"
      "embed" in capabilities -> "embeddings"
      true -> nil
    end
  end

  defp put_model(params, %Deployment{model_name: model}) when is_binary(model),
    do: Map.put(params, "model", model)

  defp put_model(params, _), do: params

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp to_model_ids({:ok, body}), do: {:ok, Airo.Adapter.model_ids(body)}
  defp to_model_ids({:error, _} = error), do: error

  defp request_text(ctx, path) do
    opts =
      [
        finch: Airo.Finch,
        headers: Transport.auth_headers(ctx.provider),
        receive_timeout: 30_000,
        retry: false
      ]
      |> Keyword.merge(global_req_options())
      |> Keyword.merge(Keyword.get(ctx.opts, :req_options, []))

    Req.new(opts)
    |> Req.get(url: Transport.full_url(ctx.provider.base_url, path))
    |> normalize()
  end

  defp normalize({:ok, %Req.Response{status: status, body: body, headers: headers}}) do
    {:ok, %{status: status, body: body, headers: Map.new(headers)}}
  end

  defp normalize({:error, reason}), do: {:error, reason}

  defp global_req_options do
    Application.get_env(:airo, Airo.Transport, []) |> Keyword.get(:req_options, [])
  end
end
