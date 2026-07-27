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
  alias Airo.{Engines, LocalProvider, Registry, Repo}

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

  def capabilities(%Provider{} = provider) do
    case management_module(provider) do
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
    with {:ok, module} <- management_module(provider),
         true <- LocalProvider.supports?(module, capability) do
      {:ok, module}
    else
      false -> {:error, :unsupported}
      {:error, :no_adapter} = error -> error
    end
  end

  # Which module manages this provider's local models.
  #
  # `adapter_type` names the *wire protocol*, and every agent-managed slot is
  # `:openai` whatever engine runs behind it — so resolving on it alone gave a
  # managed vLLM slot none of the `/metrics` and `max_model_len` reporting an
  # external vLLM provider gets. For managed slots, resolve on the engine
  # instead; external providers keep resolving on `adapter_type`, which is what
  # identifies their backend.
  defp management_module(%Provider{agent_id: nil} = provider),
    do: Registry.fetch(provider.adapter_type)

  defp management_module(%Provider{} = provider) do
    case provider |> provider_engine() |> Engines.local_provider() do
      nil -> Registry.fetch(provider.adapter_type)
      module -> {:ok, module}
    end
  end

  # A managed slot holds one model at a time, so any linked model's engine
  # identifies the slot. `nil` for an unsaved provider or one with nothing bound
  # yet — the caller falls back to `adapter_type`.
  defp provider_engine(%Provider{id: nil}), do: nil

  defp provider_engine(%Provider{} = provider) do
    provider
    |> Repo.preload(deployments: :model)
    |> Map.fetch!(:deployments)
    |> Enum.find_value(fn deployment -> deployment.model && deployment.model.engine end)
  end

  defp context(provider) do
    provider
    |> Repo.preload(:credential)
    |> Context.new(opts: [req_options: @req_options])
  end
end
