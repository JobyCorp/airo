defmodule AiroWeb.ModelsController do
  @moduledoc """
  Unified model list: `GET /v1/models` (DESIGN §5). Returns the OpenAI-shaped
  list of callable `model` values for the client key — both the logical
  **aliases** and the concrete **deployment model ids** (which the gateway also
  resolves directly). Scoped to the key's `allowed_aliases`.

  Each entry carries a non-standard `capabilities` array so a client knows which
  endpoint a given id is for (e.g. `BAAI/bge-m3` is embeddings, not chat) — the
  list advertises every servable id rather than hiding non-chat ones.
  """
  use AiroWeb, :controller

  alias Airo.Config
  alias Airo.Config.ClientKey

  def index(conn, _params) do
    client_key = conn.assigns.client_key

    aliases = Config.list_aliases()
    alias_names = Enum.map(aliases, & &1.name)
    alias_set = MapSet.new(alias_names)
    alias_caps = Map.new(aliases, &{&1.name, [to_string(&1.capability)]})

    deployments = Config.list_deployments()

    # Union capabilities across all deployments sharing a model id.
    model_caps =
      Enum.reduce(deployments, %{}, fn d, acc ->
        Map.update(acc, d.model_name, caps(d), &Enum.uniq(&1 ++ caps(d)))
      end)

    model_names =
      deployments
      |> Enum.map(& &1.model_name)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(alias_set, &1))

    caps_by_id = Map.merge(model_caps, alias_caps)

    data =
      (alias_names ++ model_names)
      |> Enum.filter(&ClientKey.scoped?(client_key, &1))
      |> Enum.map(&model_entry(&1, Map.get(caps_by_id, &1, [])))

    json(conn, %{"object" => "list", "data" => data})
  end

  defp caps(deployment), do: Enum.map(deployment.capabilities, &to_string/1)

  defp model_entry(id, capabilities) do
    %{
      "id" => id,
      "object" => "model",
      "created" => 0,
      "owned_by" => "airo",
      "capabilities" => capabilities
    }
  end
end
