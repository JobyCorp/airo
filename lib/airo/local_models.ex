defmodule Airo.LocalModels do
  @moduledoc """
  Local model inventory/control facade.

  This deliberately targets local providers first. Cloud/remote providers may
  expose catalogs, but installing or controlling remote model artifacts is out of
  scope for the Model Shelf's local management slice.
  """

  alias Airo.Adapter.Context
  alias Airo.Config
  alias Airo.Config.{Deployment, Model, Provider}
  alias Airo.{LocalProvider, Registry, Repo}

  @req_options [receive_timeout: 30_000]

  @spec sync_deployment(Deployment.t()) :: {:ok, Deployment.t()} | {:error, term()}
  def sync_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:provider, :model])

    with {:ok, inspected} <- inspect_model(deployment.provider, deployment.model_name),
         runtime <- runtime_info_or_empty(deployment.provider),
         {:ok, _model} <- update_model_from_metadata(deployment.model, inspected),
         {:ok, deployment} <-
           Config.update_deployment(deployment, %{
             provider_metadata: provider_metadata(deployment, inspected, runtime)
           }) do
      {:ok, Repo.preload(deployment, [:provider, :model], force: true)}
    end
  end

  @spec catalog(Provider.t()) :: {:ok, list(map())} | {:error, term()}
  def catalog(%Provider{} = provider) do
    with {:ok, module} <- local_module(provider, :catalog) do
      provider |> context() |> module.catalog()
    end
  end

  @spec inspect_model(Provider.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def inspect_model(%Provider{} = provider, model_id) when is_binary(model_id) do
    with {:ok, module} <- local_module(provider, :inspect_model) do
      provider |> context() |> then(&module.inspect_model(model_id, &1))
    end
  end

  @spec pull_model(Provider.t(), map()) :: {:ok, map()} | {:error, term()}
  def pull_model(%Provider{} = provider, attrs) when is_map(attrs) do
    with {:ok, module} <- local_module(provider, :pull_model) do
      provider |> context() |> then(&module.pull_model(attrs, &1))
    end
  end

  @spec runtime_info(Provider.t()) :: {:ok, map()} | {:error, term()}
  def runtime_info(%Provider{} = provider) do
    with {:ok, module} <- local_module(provider, :runtime_info) do
      provider |> context() |> module.runtime_info()
    end
  end

  @doc "Load a model on a lifecycle-owned provider (e.g. :airo_agent)."
  @spec load_model(Provider.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def load_model(%Provider{} = provider, model_id, profile \\ %{})
      when is_binary(model_id) and is_map(profile) do
    with {:ok, module} <- local_module(provider, :load_model) do
      provider |> context() |> then(&module.load_model(model_id, profile, &1))
    end
  end

  @doc "Unload a model on a lifecycle-owned provider."
  @spec unload_model(Provider.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def unload_model(%Provider{} = provider, model_id) when is_binary(model_id) do
    with {:ok, module} <- local_module(provider, :unload_model) do
      provider |> context() |> then(&module.unload_model(model_id, &1))
    end
  end

  def capabilities(%Provider{} = provider) do
    case Registry.fetch(provider.adapter_type) do
      {:ok, module} ->
        Enum.filter(LocalProvider.capabilities(), &LocalProvider.supports?(module, &1))

      {:error, :no_adapter} ->
        []
    end
  end

  defp runtime_info_or_empty(provider) do
    case runtime_info(provider) do
      {:ok, runtime} -> runtime
      {:error, _reason} -> %{}
    end
  end

  defp update_model_from_metadata(nil, _metadata), do: {:ok, nil}

  defp update_model_from_metadata(%Model{} = model, metadata) do
    attrs =
      %{
        family: metadata[:family],
        quantization: metadata[:quantization],
        size: metadata[:parameter_size],
        # The provenance payoff: HF snapshot sha → the shelf's REVISION column.
        revision: metadata[:revision]
      }
      |> drop_empty()

    Config.update_model(model, attrs)
  end

  defp provider_metadata(deployment, inspected, runtime) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{
      "provider_type" => to_string(deployment.provider.adapter_type),
      "provider_name" => deployment.provider.name,
      "synced_at" => now,
      "family" => inspected[:family],
      "families" => inspected[:families] || [],
      "format" => inspected[:format],
      "quantization" => inspected[:quantization],
      "parameter_size" => inspected[:parameter_size],
      "architecture" => inspected[:architecture],
      "context_window" => inspected[:context_window],
      "max_context_window" => inspected[:max_context_window],
      "publisher" => inspected[:publisher],
      "type" => inspected[:type],
      "task" => inspected[:task],
      "root" => inspected[:root],
      "owned_by" => inspected[:owned_by],
      "created" => inspected[:created],
      "backend" => inspected[:backend],
      "modelfile" => inspected[:modelfile],
      "template" => inspected[:template],
      "parameters" => inspected[:parameters],
      "license" => inspected[:license],
      "permissions" => inspected[:permissions],
      "loaded_instances" => inspected[:loaded_instances],
      "capabilities" => inspected[:capabilities],
      "vision" => inspected[:vision],
      "trained_for_tool_use" => inspected[:trained_for_tool_use],
      "reasoning" => inspected[:reasoning],
      "variants" => inspected[:variants],
      "selected_variant" => inspected[:selected_variant],
      "description" => inspected[:description],
      "languages" => inspected[:languages],
      "language_count" => inspected[:language_count],
      "sample_rate" => inspected[:sample_rate],
      "voices" => inspected[:voices],
      "voice_count" => inspected[:voice_count],
      "voice_languages" => inspected[:voice_languages],
      "stats" => inspected[:stats],
      "queue_fraction" => inspected[:queue_fraction],
      "queue_absolute" => inspected[:queue_absolute],
      "results_pending" => inspected[:results_pending],
      "batch_size" => inspected[:batch_size],
      "runtime_version" => runtime[:version],
      "running" => running?(runtime, deployment.model_name),
      "metrics" => metrics_for(runtime[:metrics], deployment),
      "raw" => %{
        "inspect" => stringify(inspected[:raw] || %{}),
        "runtime" => stringify(runtime)
      }
    }
    |> drop_empty()
  end

  defp running?(%{running: running}, model_name) when is_list(running) do
    Enum.any?(running, &running_model_match?(&1, model_name))
  end

  defp running?(_runtime, _model_name), do: false

  defp running_model_match?(model, model_name) do
    model[:id] == model_name or
      model["id"] == model_name or
      model[:selected_variant] == model_name or
      model["selected_variant"] == model_name or
      model[:root] == model_name or
      model["root"] == model_name or
      model[:task] == model_name or
      model["task"] == model_name or
      model_name in (model[:variants] || model["variants"] || []) or
      Enum.any?(model[:loaded_instances] || model["loaded_instances"] || [], fn instance ->
        instance[:id] == model_name or instance["id"] == model_name
      end)
  end

  defp metrics_for(metrics, deployment) when is_map(metrics) do
    Map.get(metrics, deployment.model_name) ||
      Map.get(metrics, to_string(deployment.model_name)) ||
      Map.get(metrics, capability_handler(deployment.capabilities))
  end

  defp metrics_for(_metrics, _deployment), do: nil

  defp capability_handler([:embeddings | _]), do: "embeddings"
  defp capability_handler(["embeddings" | _]), do: "embeddings"
  defp capability_handler([:rerank | _]), do: "rerank"
  defp capability_handler(["rerank" | _]), do: "rerank"
  defp capability_handler([:classify | _]), do: "classify"
  defp capability_handler(["classify" | _]), do: "classify"
  defp capability_handler([capability | _]), do: to_string(capability)
  defp capability_handler(_capabilities), do: nil

  defp drop_empty(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", []] end)
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp stringify(value), do: value

  defp local_module(provider, capability) do
    with {:ok, module} <- Registry.fetch(provider.adapter_type),
         true <- LocalProvider.supports?(module, capability) do
      {:ok, module}
    else
      false -> {:error, :unsupported}
      {:error, :no_adapter} = error -> error
    end
  end

  defp context(provider) do
    provider
    |> Repo.preload(:credential)
    |> Context.new(opts: [req_options: @req_options])
  end
end
