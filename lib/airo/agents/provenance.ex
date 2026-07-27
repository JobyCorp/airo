defmodule Airo.Agents.Provenance do
  @moduledoc """
  Reconcile a managed slot's resident model into the Model Shelf (S19, see
  [DESIGN-agent-provenance.md](../../../docs/design/DESIGN-agent-provenance.md)).

  The agent's model id (`repo:quant`) is the *real model name* and is **not
  unique** — the same model is copied across hosts (and could share a host across
  slots). So Airo's canonical `Model.upstream_model_id` is **host/slot-qualified**
  (`<host_id>_<resident_id>_<slot>`), while `display_name` carries the real name.

  Given the inventory `provenance` for the resident id, `reconcile/4` ensures that
  Model exists and is enriched (revision/family/quantization/size), re-keying a
  legacy filename-named Model in place. It is **scoped to the slot's own
  provider** — it never reaches an external (`agent_id = null`) provider's Model.
  """

  require Logger

  alias Airo.Config
  alias Airo.Repo

  @doc """
  Reconcile the resident model of one slot `provider`. `provenance` is the
  inventory entry (string-keyed) for the resident id, or `nil` when inventory is
  unavailable (identity-only reconcile). Returns the `Model`, or `nil` for an
  empty slot.
  """
  def reconcile(host_id, provider, slot, provenance) do
    case slot["resident_model"] do
      id when is_binary(id) and id != "" ->
        key = identity(host_id, id, slot["port"])
        model = upsert_model(provider, key, model_attrs(key, id, slot, provenance), provenance)
        link_deployment(provider, model, id, provenance)
        model

      _empty ->
        nil
    end
  end

  @doc "The host/slot-qualified canonical id for a resident model."
  def identity(host_id, resident_id, slot), do: "#{host_id}_#{resident_id}_#{slot}"

  defp model_attrs(key, resident_id, slot, prov) do
    %{
      upstream_model_id: key,
      display_name: resident_id,
      revision: slot["revision"] || prov_get(prov, "revision"),
      family: prov_get(prov, "family"),
      quantization: prov_get(prov, "quant"),
      size: humanize_size(prov_get(prov, "size_bytes")),
      # The engine is the only thing distinguishing a llama.cpp slot from a vLLM
      # one — both are `adapter_type: :openai` on the wire — and it decides how
      # capacity, sampling knobs and local management behave (S22).
      engine: prov_get(prov, "engine")
    }
    |> reject_nil()
  end

  # Find by the canonical key, else re-key a legacy filename-named Model in place,
  # else create. Enrichment never overwrites with nil and never resets lifecycle.
  defp upsert_model(provider, key, attrs, prov) do
    cond do
      model = Config.get_model_by_upstream_id(key) ->
        enrich(model, attrs)

      legacy = legacy_model(provider, prov) ->
        Logger.info("provenance: re-keying legacy model #{legacy.id} → #{key}")
        enrich(legacy, attrs)

      true ->
        {:ok, model} = Config.create_model(Map.put(attrs, :status, :evaluating))
        model
    end
  end

  defp enrich(model, attrs) do
    {:ok, model} = Config.update_model(model, attrs)
    model
  end

  # A Model reached via THIS slot provider's deployment whose name is the resident
  # model's GGUF filename. Guarded to the provider so it can't touch an external
  # provider's Model.
  defp legacy_model(_provider, nil), do: nil

  defp legacy_model(provider, prov) do
    with base when is_binary(base) <- basename(prov["path"]),
         %{deployments: deployments} <- Repo.preload(provider, deployments: :model),
         %{model: %{} = model} <-
           Enum.find(deployments, &(&1.model_name == base and &1.model)) do
      model
    else
      _ -> nil
    end
  end

  # Point the slot's matching deployment at the canonical Model (a no-op once
  # aligned). A deployment matches when it's already linked, or its `model_name`
  # is the resident model's real id (the natural binding), the resident GGUF's
  # full local path, or just its filename (an operator can bind a slot by any of
  # these — llama-server is launched with the path). Path matching compares
  # basenames on both sides so a full-path `model_name` lines up with a bare
  # filename. Only the slot provider's own deployments are considered.
  defp link_deployment(provider, model, resident_id, prov) do
    path = prov && prov["path"]
    base = basename(path)
    %{deployments: deployments} = Repo.preload(provider, :deployments)

    matches? = fn d ->
      d.model_id == model.id or
        d.model_name == resident_id or
        (path && d.model_name == path) or
        (base && basename(d.model_name) == base)
    end

    case Enum.find(deployments, matches?) do
      %{model_id: mid} when mid == model.id -> :ok
      %{} = deployment -> Config.update_deployment(deployment, %{model_id: model.id})
      nil -> :ok
    end
  end

  defp basename(path) when is_binary(path), do: Path.basename(path)
  defp basename(_path), do: nil

  defp humanize_size(bytes) when is_integer(bytes) and bytes > 0 do
    "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
  end

  defp humanize_size(_bytes), do: nil

  defp prov_get(nil, _key), do: nil
  defp prov_get(prov, key), do: prov[key]

  defp reject_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
