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
    is OpenAI-compatible). A cold model is **auto-loaded on demand** (POST /load →
    poll the engine until ready → serve); the first request pays the cold start.
    Disable with `config :airo, :airo_agent_auto_load, false`. Eviction policy is
    a follow-up — a load that can't fit VRAM fails at the engine and surfaces here.
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
    with {:ok, ctx} <- ensure_loaded(ctx), do: OpenAICompatible.chat(params, ctx)
  end

  @impl Airo.Adapter
  def stream(params, %Context{} = ctx, acc, reducer) do
    case ensure_loaded(ctx) do
      {:ok, ctx} -> OpenAICompatible.stream(params, ctx, acc, reducer)
      {:error, reason} -> {:error, reason, acc}
    end
  end

  @impl Airo.Adapter
  def embed(params, %Context{} = ctx) do
    with {:ok, ctx} <- ensure_loaded(ctx), do: OpenAICompatible.embed(params, ctx)
  end

  @doc "Model ids the agent has on disk (its inventory), for discovery/pickers."
  @impl Airo.Adapter
  def list_models(%Context{} = ctx) do
    with {:ok, models} <- catalog(ctx), do: {:ok, Enum.map(models, & &1.id)}
  end

  # Resolve a context that targets the *engine*. Already serving (Ingest stashed
  # serving_base_url on :up) ⇒ retarget. Cold ⇒ auto-load on demand: POST /load,
  # wait for the engine to answer, then serve. The provider's auth rides along
  # (harmless to a keyless engine; forward-compatible with reusing the token as
  # --api-key).
  defp ensure_loaded(%Context{deployment: %Deployment{} = d} = ctx) do
    case serving_base_url(d) do
      url when is_binary(url) and url != "" ->
        {:ok, retarget(ctx, url)}

      _ ->
        if auto_load?(), do: load_and_await(ctx, d), else: {:error, :model_not_loaded}
    end
  end

  defp ensure_loaded(_ctx), do: {:error, :no_deployment}

  defp load_and_await(%Context{} = ctx, %Deployment{model_name: model_id} = d) do
    case load_model(model_id, load_profile(d), ctx) do
      {:ok, %{"base_url" => base_url}} when is_binary(base_url) ->
        deadline = System.monotonic_time(:millisecond) + load_timeout_ms()

        case await_ready(ctx, base_url, deadline) do
          :ok -> {:ok, retarget(ctx, base_url)}
          :timeout -> {:error, :load_timeout}
        end

      {:ok, _no_base_url} ->
        {:error, :load_no_base_url}

      {:error, _} = error ->
        error
    end
  end

  # Poll the engine's /models until it answers 200 (ready) or the deadline passes.
  defp await_ready(%Context{} = ctx, base_url, deadline) do
    case Transport.get(retarget(ctx, base_url), "/models", retry: false) do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(poll_ms())
          await_ready(ctx, base_url, deadline)
        end
    end
  end

  defp retarget(%Context{} = ctx, base_url),
    do: %{ctx | provider: %{ctx.provider | base_url: base_url}}

  defp serving_base_url(%Deployment{provider_metadata: meta}) when is_map(meta),
    do: meta["serving_base_url"]

  defp serving_base_url(_), do: nil

  # The launch profile Airo stores per deployment (ctx/kv-quant/jinja/reasoning…),
  # passed through verbatim. Empty ⇒ the agent applies its own default_profile.
  defp load_profile(%Deployment{provider_metadata: meta}) when is_map(meta),
    do: meta["launch_profile"] || %{}

  defp load_profile(_), do: %{}

  defp auto_load?, do: Application.get_env(:airo, :airo_agent_auto_load, true)
  defp load_timeout_ms, do: Application.get_env(:airo, :airo_agent_load_timeout_ms, 120_000)
  defp poll_ms, do: Application.get_env(:airo, :airo_agent_load_poll_ms, 500)

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

  # Lifecycle control over the agent's POST /load and /unload. Profile is the
  # opaque engine blob (ctx/kv-quant/jinja/reasoning…) the agent passes through.
  @impl Airo.LocalProvider
  def load_model(model_id, profile, %Context{} = ctx)
      when is_binary(model_id) and is_map(profile) do
    Transport.post(ctx, "/load", %{model: model_id, profile: profile}) |> handle()
  end

  @impl Airo.LocalProvider
  def unload_model(model_id, %Context{} = ctx) when is_binary(model_id) do
    Transport.post(ctx, "/unload", %{model: model_id}) |> handle()
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
