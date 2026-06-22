defmodule Airo.LocalProvider do
  @moduledoc """
  Optional local-provider management callbacks.

  Request serving remains `Airo.Adapter`'s job. These callbacks are for local
  runtimes that expose inventory/control APIs beyond OpenAI-compatible
  inference, such as Ollama and LM Studio.
  """

  alias Airo.Adapter.Context

  @type result :: {:ok, term()} | {:error, term()}

  @doc "Rich local model inventory for a provider."
  @callback catalog(Context.t()) :: result

  @doc "Provider-native metadata for one local model."
  @callback inspect_model(String.t(), Context.t()) :: result

  @doc "Start or complete a model pull/download operation."
  @callback pull_model(map(), Context.t()) :: result

  @doc "Runtime/provider state such as version and loaded models."
  @callback runtime_info(Context.t()) :: result

  @doc "Load (start serving) a model with an opaque, engine-specific profile."
  @callback load_model(model_id :: String.t(), profile :: map(), Context.t()) :: result

  @doc "Unload (stop serving) a model."
  @callback unload_model(model_id :: String.t(), Context.t()) :: result

  @optional_callbacks catalog: 1,
                      inspect_model: 2,
                      pull_model: 2,
                      runtime_info: 1,
                      load_model: 3,
                      unload_model: 2

  @capabilities [:catalog, :inspect_model, :pull_model, :runtime_info, :load_model, :unload_model]

  def capabilities, do: @capabilities

  def supports?(module, capability) when capability in @capabilities do
    Code.ensure_loaded?(module) and
      function_exported?(module, capability, arity_for(capability))
  end

  defp arity_for(:inspect_model), do: 2
  defp arity_for(:pull_model), do: 2
  defp arity_for(:unload_model), do: 2
  defp arity_for(:load_model), do: 3
  defp arity_for(_), do: 1
end
