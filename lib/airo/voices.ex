defmodule Airo.Voices do
  @moduledoc """
  Aggregated TTS voice discovery across speech providers — the data behind
  `GET /v1/audio/voices`.

  Each enabled speech `Deployment` is asked for its upstream voices via the
  provider's adapter `voices/1` (vLLM/Qwen via `/audio/voices`, Speaches via its
  model catalog). Voices are tagged with the model + provider that serves them,
  scoped to the client key, and returned in OpenAI list shape. Live by design:
  voices change as operators upload clones or swap models, so this never caches.
  """
  require Logger

  alias Airo.Adapter.Context
  alias Airo.Config
  alias Airo.Config.ClientKey
  alias Airo.Registry

  @doc """
  Voices the `:client_key` may use, optionally restricted to one `:model`. Returns
  OpenAI-list entries: `%{"id", "object" => "voice", "model", "owned_by", ...}`.
  An upstream that errors or exposes no voices contributes nothing (logged).
  """
  def list(opts) do
    client_key = Keyword.fetch!(opts, :client_key)
    model = opts[:model]

    Config.list_deployments_by_capability(:speech)
    |> Enum.filter(fn d ->
      (is_nil(model) or d.model_name == model) and ClientKey.scoped?(client_key, d.model_name)
    end)
    |> Enum.flat_map(&deployment_voices/1)
  end

  defp deployment_voices(deployment) do
    provider = deployment.provider

    with {:ok, adapter} <- Registry.fetch(provider.adapter_type),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :voices, 1),
         {:ok, voices} <- adapter.voices(Context.new(provider, deployment: deployment)) do
      Enum.map(voices, &entry(&1, deployment, provider))
    else
      {:error, reason} ->
        Logger.warning(
          "voices: #{provider.name}/#{deployment.model_name} failed: #{inspect(reason)}"
        )

        []

      _ ->
        []
    end
  end

  defp entry(voice, deployment, provider) do
    voice
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.merge(%{
      "object" => "voice",
      "model" => deployment.model_name,
      "owned_by" => provider.name
    })
  end
end
