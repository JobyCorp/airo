defmodule Airo.LocalModels do
  @moduledoc """
  Local model inventory/control facade.

  This deliberately targets local providers first. Cloud/remote providers may
  expose catalogs, but installing or controlling remote model artifacts is out of
  scope for the Model Shelf's local management slice.
  """

  alias Airo.Adapter.Context
  alias Airo.Config.Provider
  alias Airo.{LocalProvider, Registry, Repo}

  @req_options [receive_timeout: 30_000]

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
    case Registry.fetch(provider.adapter_type) do
      {:ok, module} ->
        Enum.filter(LocalProvider.capabilities(), &LocalProvider.supports?(module, &1))

      {:error, :no_adapter} ->
        []
    end
  end

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
