defmodule Airo.Models do
  @moduledoc """
  Discovers the models a provider's upstream advertises (its `/models` catalog),
  for the admin UI's deployment form — so operators pick a real model id instead
  of typing one.

  Best-effort and synchronous: it makes a short-timeout HTTP call to the upstream
  and returns `{:error, _}` when the provider has no adapter, the adapter can't
  list a catalog, or the upstream is unreachable. Callers fall back to free text.
  """

  alias Airo.Adapter.Context
  alias Airo.Config.Provider
  alias Airo.{Registry, Repo}

  # Keep the form responsive even when an upstream is slow or down. (Connect
  # timeouts live on the Finch pool, not here — Req rejects :connect_options
  # alongside a shared :finch instance.)
  @req_options [receive_timeout: 5_000]

  @doc """
  List the model ids `provider` advertises. Preloads the provider's credential so
  authenticated catalogs (e.g. Anthropic, keyed OpenAI) resolve their headers.
  """
  @spec list(Provider.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(%Provider{} = provider) do
    with {:ok, module} <- Registry.fetch(provider.adapter_type),
         true <- lists_models?(module) do
      provider
      |> Repo.preload(:credential)
      |> Context.new(opts: [req_options: @req_options])
      |> module.list_models()
    else
      false -> {:error, :unsupported}
      {:error, :no_adapter} = error -> error
    end
  end

  defp lists_models?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :list_models, 1)
  end
end
