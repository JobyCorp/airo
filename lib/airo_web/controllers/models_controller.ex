defmodule AiroWeb.ModelsController do
  @moduledoc """
  Unified model list: `GET /v1/models` (DESIGN §5). Returns the OpenAI-shaped
  list of callable `model` values for the client key — both the logical
  **aliases** and the concrete **deployment model ids** (which the gateway also
  resolves directly). Scoped to the key's `allowed_aliases`.
  """
  use AiroWeb, :controller

  alias Airo.Config
  alias Airo.Config.ClientKey

  def index(conn, _params) do
    client_key = conn.assigns.client_key

    alias_names = Config.list_aliases() |> Enum.map(& &1.name)
    alias_set = MapSet.new(alias_names)

    model_names =
      Config.list_deployments()
      |> Enum.map(& &1.model_name)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(alias_set, &1))

    data =
      (alias_names ++ model_names)
      |> Enum.filter(&ClientKey.scoped?(client_key, &1))
      |> Enum.map(&model_entry/1)

    json(conn, %{"object" => "list", "data" => data})
  end

  defp model_entry(id) do
    %{"id" => id, "object" => "model", "created" => 0, "owned_by" => "airo"}
  end
end
