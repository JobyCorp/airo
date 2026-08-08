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
    Anthropic,
    Codex,
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
    codex: Codex,
    infinity: Infinity
  }

  @doc """
  Fetch the adapter module for an `adapter_type`.

  Note that an **agent-managed slot is always `:openai`** whatever engine is
  behind it — that field names the wire protocol, not the backend. So `:vllm`
  here means "an external vLLM someone else runs", and a vLLM slot Airo manages
  resolves to `OpenAICompatible`. `Airo.Config.Model.engine` is what identifies
  the engine of a managed slot.

      iex> Airo.Registry.fetch(:vllm)
      {:ok, Airo.Adapters.VLLM}

      iex> Airo.Registry.fetch(:openai)
      {:ok, Airo.Adapters.OpenAICompatible}

      iex> Airo.Registry.fetch(:tgi)
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
