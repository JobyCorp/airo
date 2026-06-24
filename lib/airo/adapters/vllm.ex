defmodule Airo.Adapters.VLLM do
  @moduledoc """
  vLLM adapter.

  Inference uses vLLM's OpenAI-compatible `/v1` surface via
  `Airo.Adapters.OpenAICompatible`. Local model management is read-only:
  `/v1/models` reports served model identity and `/metrics` reports runtime
  posture. vLLM does not manage local pulls/loads through this gateway path.
  """
  @behaviour Airo.Adapter
  @behaviour Airo.LocalProvider

  alias Airo.Adapter.Context
  alias Airo.Adapters.OpenAICompatible
  alias Airo.Transport

  @metric_names [
    "vllm:num_requests_running",
    "vllm:num_requests_waiting",
    "vllm:kv_cache_usage_perc",
    "vllm:prompt_tokens_total",
    "vllm:generation_tokens_total",
    "vllm:num_preemptions_total",
    "vllm:request_success_total"
  ]

  @impl Airo.Adapter
  def chat(params, %Context{} = ctx), do: OpenAICompatible.chat(params, ctx)

  @impl Airo.Adapter
  def stream(params, %Context{} = ctx, acc, reducer),
    do: OpenAICompatible.stream(params, ctx, acc, reducer)

  @impl Airo.Adapter
  def embed(params, %Context{} = ctx), do: OpenAICompatible.embed(params, ctx)

  # vLLM's omni/audio builds (e.g. Qwen3-TTS) expose OpenAI's `/audio/speech` and
  # `/audio/transcriptions` on the same `/v1` surface — delegate like the rest.
  @impl Airo.Adapter
  def speech(params, %Context{} = ctx), do: OpenAICompatible.speech(params, ctx)

  @impl Airo.Adapter
  def transcribe(params, %Context{} = ctx), do: OpenAICompatible.transcribe(params, ctx)

  @impl Airo.Adapter
  def list_models(%Context{} = ctx), do: OpenAICompatible.list_models(ctx)

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
    root = model["root"]

    %{
      id: id,
      display_name: id,
      family: family(root || id),
      quantization: quantization(root || id),
      parameter_size: parameter_size(root || id),
      root: root,
      owned_by: model["owned_by"],
      created: model["created"],
      context_window: model["max_model_len"],
      max_context_window: model["max_model_len"],
      permissions: model["permission"] || [],
      raw: model
    }
  end

  defp catalog_model(model), do: %{id: nil, display_name: nil, raw: model}

  defp inspect_metadata(model) do
    %{
      id: model.id,
      display_name: model.display_name,
      family: model.family,
      quantization: model.quantization,
      parameter_size: model.parameter_size,
      root: model.root,
      owned_by: model.owned_by,
      created: model.created,
      context_window: model.context_window,
      max_context_window: model.max_context_window,
      permissions: model.permissions,
      raw: model.raw
    }
  end

  defp find_model(models, model_id) do
    case Enum.find(models, &(&1.id == model_id || &1.root == model_id)) do
      nil -> {:error, {:not_found, model_id}}
      model -> {:ok, model}
    end
  end

  defp metrics(ctx) do
    ctx
    |> native_get("/metrics")
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

  defp put_metric(acc, name, %{"model_name" => model_name} = labels, value) do
    metric = name |> String.replace("vllm:", "") |> String.replace(":", "_")

    acc
    |> Map.update(model_name, %{metric => value}, &Map.put(&1, metric, value))
    |> put_labeled_metric(model_name, metric, labels, value)
  end

  defp put_metric(acc, _name, _labels, _value), do: acc

  defp put_labeled_metric(
         acc,
         model_name,
         "request_success_total",
         %{"finished_reason" => reason},
         value
       ) do
    update_in(acc, [model_name, "request_success_total_by_reason"], fn
      nil -> %{reason => value}
      reasons -> Map.put(reasons, reason, value)
    end)
  end

  defp put_labeled_metric(acc, _model_name, _metric, _labels, _value), do: acc

  defp family(value) when is_binary(value) do
    value
    |> Path.basename()
    |> String.split(["-", "_"], trim: true)
    |> List.first()
    |> case do
      nil -> nil
      family -> String.downcase(family)
    end
  end

  defp family(_value), do: nil

  defp quantization(value) when is_binary(value) do
    Regex.run(~r/(?:^|[-_])(AWQ|GPTQ|FP8|INT8|INT4|GGUF)(?:$|[-_])/i, value)
    |> case do
      [_match, quantization] -> String.upcase(quantization)
      _ -> nil
    end
  end

  defp quantization(_value), do: nil

  defp parameter_size(value) when is_binary(value) do
    Regex.run(~r/(\d+(?:\.\d+)?\s*[BM])(?:[^a-zA-Z]|$)/i, value)
    |> case do
      [_match, size] -> size |> String.replace(" ", "") |> String.upcase()
      _ -> nil
    end
  end

  defp parameter_size(_value), do: nil

  defp openai_get(ctx, path), do: request(ctx, :get, openai_base_url(ctx.provider.base_url), path)
  defp native_get(ctx, path), do: request(ctx, :get, native_base_url(ctx.provider.base_url), path)

  defp request(ctx, method, base_url, path) do
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
    url = Transport.full_url(base_url, path)

    case method do
      :get -> Req.get(req, url: url)
    end
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
