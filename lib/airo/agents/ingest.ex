defmodule Airo.Agents.Ingest do
  @moduledoc """
  Translates pushed `airo_agent` channel messages into Airo state.

  Mapping: `host_id → Provider` (by name) and `model_id → Deployment` (by
  `model_name` under that provider). For each, we apply two things:

  - **Health** — `Airo.Health.mark_deployment/4` with `source: :agent`. This
    REPLACES the `Airo.Health.Prober` for `:airo_agent` providers (which it
    skips), so health is push-driven, not polled.
  - **Serving URL** — the engine's `base_url` (from the pushed `InstanceInfo`) is
    stashed on `provider_metadata["serving_base_url"]` while the model is `:up`,
    and cleared otherwise. `Airo.Adapters.AiroAgent` reads it to route inference
    to the engine (decision #5).

  Unknown host or model ⇒ no-op (an agent may connect before its Provider /
  Deployments are configured).
  """
  require Logger

  alias Airo.{Config, Health, Repo}
  alias Airo.Config.Deployment

  @doc "One lifecycle transition: `%{\"type\" => ..., \"model_id\" => ..., \"info\" => ..., \"reason\" => ...}`."
  def event(host_id, %{"type" => type, "model_id" => model_id} = payload) do
    with %{} = provider <- Config.get_provider_by_name(host_id),
         %{} = deployment <- Config.get_deployment_by(provider.id, model_id) do
      {status, reason} = status_for(type, payload["reason"])
      serving_url = if status == :up, do: get_in(payload, ["info", "base_url"]), else: nil
      apply_state(deployment, provider, status, reason, serving_url)
    else
      _ -> :ok
    end
  end

  def event(_host_id, _payload), do: :ok

  @doc """
  Full running set. Reconciles every deployment of the host's provider: present
  and serving ⇒ up, present and loading ⇒ unknown, absent ⇒ down. This is how a
  dropped event self-heals.
  """
  def snapshot(host_id, %{"instances" => instances}) when is_list(instances) do
    case Config.get_provider_by_name(host_id) do
      %{} = provider ->
        by_model = Map.new(instances, &{&1["model_id"], &1})

        provider
        |> Repo.preload(:deployments)
        |> Map.fetch!(:deployments)
        |> Enum.each(fn deployment ->
          case Map.get(by_model, deployment.model_name) do
            nil ->
              apply_state(deployment, provider, :down, "not_running", nil)

            instance ->
              {status, serving_url} = snapshot_state(instance)
              apply_state(deployment, provider, status, nil, serving_url)
          end
        end)

      _ ->
        :ok
    end
  end

  def snapshot(_host_id, _payload), do: :ok

  @doc "The agent's socket dropped — mark every deployment of its provider down."
  def host_down(host_id) do
    case Config.get_provider_by_name(host_id) do
      %{} = provider ->
        provider
        |> Repo.preload(:deployments)
        |> Map.fetch!(:deployments)
        |> Enum.each(&apply_state(&1, provider, :down, "agent_disconnected", nil))

      _ ->
        :ok
    end
  end

  # Mark health and keep the serving URL in lockstep: present only while :up.
  defp apply_state(deployment, provider, status, reason, serving_url) do
    Health.mark_deployment(deployment, provider, status, source: :agent, reason: clip(reason))
    put_serving_url(deployment, serving_url)
    :ok
  end

  defp put_serving_url(%Deployment{provider_metadata: meta} = deployment, url) do
    meta = meta || %{}

    if meta["serving_base_url"] == url do
      :ok
    else
      new_meta =
        if url,
          do: Map.put(meta, "serving_base_url", url),
          else: Map.delete(meta, "serving_base_url")

      Config.update_deployment(deployment, %{provider_metadata: new_meta})
      :ok
    end
  end

  # Agent lifecycle type → Airo health status (preference signal, not a gate).
  defp status_for("up", _reason), do: {:up, nil}
  defp status_for("loading", _reason), do: {:unknown, "loading"}
  defp status_for("down", reason), do: {:down, reason || "down"}
  defp status_for("failed", reason), do: {:down, reason || "failed"}
  defp status_for("unloaded", _reason), do: {:down, "unloaded"}
  defp status_for(_other, _reason), do: {:unknown, nil}

  defp snapshot_state(%{"status" => "up", "base_url" => url}) when is_binary(url), do: {:up, url}
  defp snapshot_state(_instance), do: {:unknown, nil}

  # HealthEvent.reason is capped at 255; agent reasons can be inspected terms.
  defp clip(nil), do: nil
  defp clip(reason), do: reason |> to_string() |> String.slice(0, 255)
end
