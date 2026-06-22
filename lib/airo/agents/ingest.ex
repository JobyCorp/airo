defmodule Airo.Agents.Ingest do
  @moduledoc """
  Channel-facing translation of agent pushes into Airo state (Model 2).

  - `register/2` — structural + health: upsert the Agent and its slot-Providers
    (`Airo.Agents.register/2`), then seed health from each slot's resident model.
  - `slot/2` — one slot transition: re-derive health for that slot's deployments.
  - `host_down/1` — the agent disconnected: mark every deployment of its managed
    providers down.

  Health is per-deployment but driven by the slot's **resident** model: under a
  slot Provider, the deployment whose `model_name` is currently loaded takes the
  slot's status; the others are `:down` (not loaded — routing must swap them in).
  This REPLACES the prober for agent-managed providers (the prober skips any
  provider with an `agent_id`).
  """
  require Logger

  alias Airo.{Agents, Config, Health, Repo}

  @doc "Full registration (on channel join/rejoin): structure + per-slot health."
  def register(host_id, payload) when is_binary(host_id) and is_map(payload) do
    case Agents.register(host_id, payload) do
      {:ok, _} ->
        payload |> Map.get("slots", []) |> Enum.each(&apply_slot(host_id, &1))
        :ok

      {:error, reason} ->
        Logger.warning("agent #{host_id}: register failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "A single slot transition (load/up/down/swap)."
  def slot(host_id, slot) when is_binary(host_id) and is_map(slot), do: apply_slot(host_id, slot)

  @doc "The agent's socket dropped — mark every deployment of its providers down."
  def host_down(host_id) do
    case Config.get_agent_by_host_id(host_id) do
      %{} = agent ->
        agent
        |> Repo.preload(providers: :deployments)
        |> Map.fetch!(:providers)
        |> Enum.each(fn provider ->
          Enum.each(provider.deployments, fn deployment ->
            Health.mark_deployment(deployment, provider, :down,
              source: :agent,
              reason: "agent_disconnected"
            )
          end)
        end)

      _ ->
        :ok
    end
  end

  # Re-derive health for every deployment under a slot from its resident model.
  defp apply_slot(host_id, slot) do
    case Config.get_provider_by_name(slot_name(host_id, slot)) do
      %{} = provider ->
        provider = Repo.preload(provider, :deployments)
        resident = slot["resident_model"]
        {resident_status, reason} = status_for(slot["status"], slot["reason"])

        Enum.each(provider.deployments, fn deployment ->
          {status, why} =
            if deployment.model_name == resident,
              do: {resident_status, reason},
              else: {:down, "not_resident"}

          Health.mark_deployment(deployment, provider, status, source: :agent, reason: clip(why))
        end)

      _ ->
        :ok
    end
  end

  defp slot_name(host_id, slot), do: "#{host_id}:#{slot["port"]}"

  # The resident model's status. A loading slot is :unknown (don't route yet but
  # don't hard-fail); empty/crashed is :down.
  defp status_for("up", _reason), do: {:up, nil}
  defp status_for("loading", _reason), do: {:unknown, "loading"}
  defp status_for("down", reason), do: {:down, reason || "down"}
  defp status_for("failed", reason), do: {:down, reason || "failed"}
  defp status_for(_empty_or_nil, _reason), do: {:down, "empty"}

  defp clip(nil), do: nil
  defp clip(reason), do: reason |> to_string() |> String.slice(0, 255)
end
