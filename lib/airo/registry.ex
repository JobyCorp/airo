defmodule Airo.Registry do
  @moduledoc """
  Maps a provider `adapter_type` to its `Airo.Adapter` implementation (DESIGN §13).

  OpenAI-compatible upstreams may either use `Airo.Adapters.OpenAICompatible`
  directly or a provider-specific wrapper when they expose useful local
  management APIs. Anthropic and Infinity get bespoke normalizing adapters;
  until an adapter exists `fetch/1` reports `:no_adapter` so callers fail
  loudly rather than silently mis-dispatching.
  """

  alias Airo.Adapters.{
    AiroAgent,
    Anthropic,
    Infinity,
    LMStudio,
    Ollama,
    OpenAICompatible,
    Speaches,
    Unsloth,
    VLLM
  }

  @adapters %{
    openai: OpenAICompatible,
    vllm: VLLM,
    ollama: Ollama,
    lmstudio: LMStudio,
    speaches: Speaches,
    unsloth: Unsloth,
    anthropic: Anthropic,
    infinity: Infinity,
    airo_agent: AiroAgent
  }

  @doc """
  Fetch the adapter module for an `adapter_type`.

      iex> Airo.Registry.fetch(:vllm)
      {:ok, Airo.Adapters.OpenAICompatible}

      iex> Airo.Registry.fetch(:anthropic)
      {:error, :no_adapter}
  """
  @spec fetch(atom()) :: {:ok, module()} | {:error, :no_adapter}
  def fetch(adapter_type) do
    case Map.fetch(@adapters, adapter_type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :no_adapter}
    end
  end

  @doc "Like `fetch/1` but raises if no adapter is registered."
  @spec fetch!(atom()) :: module()
  def fetch!(adapter_type) do
    case fetch(adapter_type) do
      {:ok, module} -> module
      {:error, :no_adapter} -> raise ArgumentError, "no adapter for #{inspect(adapter_type)}"
    end
  end

  @doc "All registered adapter types."
  @spec adapter_types() :: [atom()]
  def adapter_types, do: Map.keys(@adapters)
end
