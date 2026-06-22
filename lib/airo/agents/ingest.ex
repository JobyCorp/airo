defmodule Airo.Agents.Ingest do
  @moduledoc """
  Translates pushed `airo_agent` channel messages into Airo health state.

  Mapping: `host_id → Provider` (by name) and `model_id → Deployment` (by
  `model_name` under that provider). Lifecycle events and snapshots become
  `Airo.Health.mark_deployment/4` calls with `source: :agent`. This REPLACES the
  `Airo.Health.Prober` for `:airo_agent` providers (which the prober skips), so
  health for agent-managed deployments is push-driven, not polled.

  Unknown host or model ⇒ no-op (an agent may connect before its Provider /
  Deployments are configured).
  """
  require Logger

  alias Airo.{Config, Health, Repo}

  @doc "One lifecycle transition: `%{\"type\" => ..., \"model_id\" => ..., \"reason\" => ...}`."
  def event(host_id, %{"type" => type, "model_id" => model_id} = payload) do
    with %{} = provider <- Config.get_provider_by_name(host_id),
         %{} = deployment <- Config.get_deployment_by(provider.id, model_id) do
      {status, reason} = status_for(type, payload["reason"])
      Health.mark_deployment(deployment, provider, status, source: :agent, reason: clip(reason))
    else
      _ -> :ok
    end
  end

  def event(_host_id, _payload), do: :ok

  @doc """
  Full running set. Reconciles every deployment of the host's provider: present
  in the snapshot ⇒ up, absent ⇒ down. This is how a dropped event self-heals.
  """
  def snapshot(host_id, %{"instances" => instances}) when is_list(instances) do
    case Config.get_provider_by_name(host_id) do
      %{} = provider ->
        running = MapSet.new(instances, & &1["model_id"])

        provider
        |> Repo.preload(:deployments)
        |> Map.fetch!(:deployments)
        |> Enum.each(fn deployment ->
          if MapSet.member?(running, deployment.model_name) do
            Health.mark_deployment(deployment, provider, :up, source: :agent)
          else
            Health.mark_deployment(deployment, provider, :down,
              source: :agent,
              reason: "not_running"
            )
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
        |> Enum.each(fn deployment ->
          Health.mark_deployment(deployment, provider, :down,
            source: :agent,
            reason: "agent_disconnected"
          )
        end)

      _ ->
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

  # HealthEvent.reason is capped at 255; agent reasons can be inspected terms.
  defp clip(nil), do: nil
  defp clip(reason), do: reason |> to_string() |> String.slice(0, 255)
end
