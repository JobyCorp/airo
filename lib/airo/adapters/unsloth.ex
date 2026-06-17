defmodule Airo.Adapters.Unsloth do
  @moduledoc """
  Unsloth Studio/local server adapter.

  Unsloth exposes an OpenAI-compatible `/v1` inference surface. Its current
  local inventory shape matches the vLLM-style `/v1/models` plus root
  `/metrics` path, so this adapter delegates to `Airo.Adapters.VLLM` while
  preserving `:unsloth` as a first-class provider type.
  """
  @behaviour Airo.Adapter
  @behaviour Airo.LocalProvider

  alias Airo.Adapter.Context
  alias Airo.Adapters.VLLM

  @impl Airo.Adapter
  def chat(params, %Context{} = ctx), do: VLLM.chat(params, ctx)

  @impl Airo.Adapter
  def stream(params, %Context{} = ctx, acc, reducer), do: VLLM.stream(params, ctx, acc, reducer)

  @impl Airo.Adapter
  def embed(params, %Context{} = ctx), do: VLLM.embed(params, ctx)

  @impl Airo.Adapter
  def list_models(%Context{} = ctx), do: VLLM.list_models(ctx)

  @impl Airo.LocalProvider
  def catalog(%Context{} = ctx), do: VLLM.catalog(ctx)

  @impl Airo.LocalProvider
  def inspect_model(model, %Context{} = ctx), do: VLLM.inspect_model(model, ctx)

  @impl Airo.LocalProvider
  def runtime_info(%Context{} = ctx), do: VLLM.runtime_info(ctx)
end
