defmodule AiroWeb.ModelsController do
  @moduledoc """
  Unified model list: `GET /v1/models` (DESIGN §5). Returns the OpenAI-shaped
  list of callable `model` values for the client key — both the logical
  **aliases** and the concrete **deployment model ids** (which the gateway also
  resolves directly). Scoped to the key's `allowed_aliases`.

  Each entry carries a non-standard `capabilities` array so a client knows which
  endpoint a given id is for (e.g. `BAAI/bge-m3` is embeddings, not chat) — the
  list advertises every servable id rather than hiding non-chat ones.

  Entries also carry a non-standard `context_length`: the smallest known
  `context_window` among the enabled deployments that could serve the id (an
  alias uses its own candidates, not its fallback chain — fallbacks are
  degradation paths, not the bound sessions should be sized to). `null` when no
  serving copy declares a window. Consumers size prompts/compaction against
  this instead of hardcoding serving facts.
  """
  use AiroWeb, :controller

  alias Airo.Config
  alias Airo.Config.ClientKey
  alias Airo.Repo

  def index(conn, _params) do
    client_key = conn.assigns.client_key

    aliases = Config.list_aliases() |> Repo.preload(:candidates)
    alias_names = Enum.map(aliases, & &1.name)
    alias_set = MapSet.new(alias_names)
    alias_caps = Map.new(aliases, &{&1.name, [to_string(&1.capability)]})

    deployments = Config.list_deployments()
    deployment_by_id = Map.new(deployments, &{&1.id, &1})

    # Union capabilities across all deployments sharing a model id.
    model_caps =
      Enum.reduce(deployments, %{}, fn d, acc ->
        Map.update(acc, d.model_name, caps(d), &Enum.uniq(&1 ++ caps(d)))
      end)

    model_ctx =
      Enum.reduce(deployments, %{}, fn d, acc ->
        Map.update(acc, d.model_name, ctx(d), &min_ctx(&1, ctx(d)))
      end)

    alias_ctx =
      Map.new(aliases, fn a ->
        {a.name,
         a.candidates
         |> Enum.map(&Map.get(deployment_by_id, &1.deployment_id))
         |> Enum.reject(&is_nil/1)
         |> Enum.reduce(nil, fn d, acc -> min_ctx(acc, ctx(d)) end)}
      end)

    caps_by_id = Map.merge(model_caps, alias_caps)
    ctx_by_id = Map.merge(model_ctx, alias_ctx)

    data =
      (alias_names ++ model_names(deployments, alias_set))
      |> Enum.filter(&ClientKey.scoped?(client_key, &1))
      |> Enum.map(&model_entry(&1, Map.get(caps_by_id, &1, []), Map.get(ctx_by_id, &1)))

    json(conn, %{"object" => "list", "data" => data})
  end

  defp model_names(deployments, alias_set) do
    deployments
    |> Enum.map(& &1.model_name)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(alias_set, &1))
  end

  defp caps(deployment), do: Enum.map(deployment.capabilities, &to_string/1)

  # A disabled deployment can never serve, so its window doesn't bound anything.
  defp ctx(%{enabled: true, context_window: window}), do: window
  defp ctx(_deployment), do: nil

  defp min_ctx(nil, window), do: window
  defp min_ctx(window, nil), do: window
  defp min_ctx(a, b), do: min(a, b)

  defp model_entry(id, capabilities, context_length) do
    %{
      "id" => id,
      "object" => "model",
      "created" => 0,
      "owned_by" => "airo",
      "capabilities" => capabilities,
      "context_length" => context_length
    }
  end
end
