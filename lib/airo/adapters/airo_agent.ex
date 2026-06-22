defmodule Airo.Adapters.AiroAgent do
  @moduledoc """
  Adapter for a host-side `airo_agent` control surface (decision #5).

  Unlike the consume-only adapters, this one is *lifecycle-owned*: the agent's
  `Provider.base_url` is its **control** API (`/inventory`, `/running`, `/gpu`),
  not an inference endpoint. So the two halves target different URLs:

  - **Serving** (`chat`/`stream`/`embed`) routes to the **engine**, whose URL the
    agent pushed as `InstanceInfo.base_url` and `Airo.Agents.Ingest` stashed on
    the deployment as `provider_metadata["serving_base_url"]`. We retarget the
    context and delegate to `Airo.Adapters.OpenAICompatible` (bare `llama-server`
    is OpenAI-compatible). A model that isn't loaded ⇒ `{:error, :model_not_loaded}`
    (auto-load-on-route is decision #6).
  - **Management** (`Airo.LocalProvider`) hits the control API and surfaces the
    HF-snapshot `revision` provenance Ollama/LM Studio can't.
  """
  @behaviour Airo.Adapter
  @behaviour Airo.LocalProvider

  alias Airo.Adapter.Context
  alias Airo.Adapters.OpenAICompatible
  alias Airo.Config.Deployment
  alias Airo.Transport

  # --- Airo.Adapter: serving routes to the engine, not the agent ---

  @impl Airo.Adapter
  def chat(params, %Context{} = ctx) do
    with {:ok, ctx} <- engine_ctx(ctx), do: OpenAICompatible.chat(params, ctx)
  end

  @impl Airo.Adapter
  def stream(params, %Context{} = ctx, acc, reducer) do
    case engine_ctx(ctx) do
      {:ok, ctx} -> OpenAICompatible.stream(params, ctx, acc, reducer)
      {:error, reason} -> {:error, reason, acc}
    end
  end

  @impl Airo.Adapter
  def embed(params, %Context{} = ctx) do
    with {:ok, ctx} <- engine_ctx(ctx), do: OpenAICompatible.embed(params, ctx)
  end

  @doc "Model ids the agent has on disk (its inventory), for discovery/pickers."
  @impl Airo.Adapter
  def list_models(%Context{} = ctx) do
    with {:ok, models} <- catalog(ctx), do: {:ok, Enum.map(models, & &1.id)}
  end

  # Retarget the context's base_url to the loaded engine; OpenAICompatible does
  # the rest. The provider's auth rides along (harmless to a keyless engine, and
  # forward-compatible with reusing AIRO_AGENT_TOKEN as --api-key).
  defp engine_ctx(%Context{deployment: %Deployment{} = d} = ctx) do
    case serving_base_url(d) do
      url when is_binary(url) and url != "" ->
        {:ok, %{ctx | provider: %{ctx.provider | base_url: url}}}

      _ ->
        {:error, :model_not_loaded}
    end
  end

  defp engine_ctx(_ctx), do: {:error, :model_not_loaded}

  defp serving_base_url(%Deployment{provider_metadata: meta}) when is_map(meta),
    do: meta["serving_base_url"]

  defp serving_base_url(_), do: nil

  # --- Airo.LocalProvider: management over the agent control API ---

  @impl Airo.LocalProvider
  def catalog(%Context{} = ctx) do
    case Transport.get(ctx, "/inventory") |> handle() do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok, Enum.map(models, &model_metadata/1)}

      {:ok, _other} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  @impl Airo.LocalProvider
  def inspect_model(model_id, %Context{} = ctx) when is_binary(model_id) do
    case Transport.get(ctx, "/inventory") |> handle() do
      {:ok, %{"models" => models}} when is_list(models) ->
        case Enum.find(models, &(&1["id"] == model_id)) do
          nil -> {:error, :not_found}
          model -> {:ok, model_metadata(model)}
        end

      {:ok, _other} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  @impl Airo.LocalProvider
  def runtime_info(%Context{} = ctx) do
    running =
      case Transport.get(ctx, "/running") |> handle() do
        {:ok, %{"instances" => instances}} when is_list(instances) -> instances
        _ -> []
      end

    gpu =
      case Transport.get(ctx, "/gpu") |> handle() do
        {:ok, %{} = snapshot} -> snapshot
        _ -> %{}
      end

    {:ok, %{running: running, gpu: gpu}}
  end

  # The agent's ModelRef JSON → the metadata shape the shelf consumes. `revision`
  # is the HF snapshot sha — the provenance payoff.
  defp model_metadata(model) do
    %{
      id: model["id"],
      display_name: model["id"],
      family: model["family"],
      quantization: model["quant"],
      revision: model["revision"],
      parameter_size: nil,
      size: model["size_bytes"],
      context_window: model["ctx_max"],
      max_context_window: model["ctx_max"],
      format: "gguf",
      backend: model["engine"],
      capabilities: model["capabilities"] || [],
      raw: model
    }
  end

  defp handle({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp handle({:ok, %{status: status, body: body}}), do: {:error, {:http_error, status, body}}
  defp handle({:error, reason}), do: {:error, {:transport_error, reason}}
end
