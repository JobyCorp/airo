defmodule Airo.Agents.Ingest do
  @moduledoc """
  Channel-facing translation of agent pushes into Airo state (Model 2).

  - `register/2` — structural + state: upsert the Agent and its slot-Providers
    (`Airo.Agents.register/2`), then apply each slot's pushed state.
  - `slot/2` — one slot transition (load/up/down/swap).
  - `host_down/1` — the agent disconnected: mark every deployment of its managed
    providers down and clear its slot state.

  Each slot push does two things (S17):

  1. **Resident-model state** → `Airo.Agents.SlotState`: the authoritative record
     of which model is loaded in the slot, sourced from the push. The `/agents` UI
     reads this — it is *not* inferred from deployments, since loading a model
     writes no `deployments` row.
  2. **Deployment health** (where deployments exist): a deployment whose
     `model_name` matches the resident model takes the slot's status, the rest are
     `:down`. This REPLACES the prober for agent-managed providers (the prober
     skips any provider with an `agent_id`), so routing still has a health signal
     for any deployment an operator binds to the slot.

  Both are broadcast on `agent:<host_id>` so the live UI updates without polling.
  """
  require Logger

  alias Airo.{Agents, Config, Health, Repo}
  alias Airo.Agents.SlotState

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

  @doc "The agent's socket dropped — mark its deployments down and forget slot state."
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

          SlotState.clear(provider.id)
        end)

        broadcast(host_id)

      _ ->
        :ok
    end
  end

  # Apply one slot's pushed state: record the resident model (SlotState) and
  # re-derive health for any deployments bound to the slot.
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

        SlotState.put(provider.id, %{
          resident_model: resident,
          revision: slot["revision"],
          status: slot["status"],
          reason: clip(slot["reason"])
        })

        broadcast(host_id)

      _ ->
        :ok
    end
  end

  @doc "PubSub topic carrying a host's slot-state changes (distinct from the channel topic)."
  def slots_topic(host_id), do: "agent_slots:#{host_id}"

  # Tell live views watching this host that its slot state changed. Uses a
  # dedicated topic — broadcasting on the channel topic ("agent:<host_id>") would
  # deliver this to the AgentChannel process, which doesn't expect it.
  defp broadcast(host_id) do
    Phoenix.PubSub.broadcast(Airo.PubSub, slots_topic(host_id), {:agent_slots, host_id})
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
