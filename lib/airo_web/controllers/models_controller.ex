defmodule AiroWeb.ModelsController do
  @moduledoc """
  Unified model list: `GET /v1/models` (DESIGN §5). Returns the OpenAI-shaped
  list of logical models a client may call — Airo's aliases, scoped to the
  client key's `allowed_aliases`. (The alias is what a consumer puts in `model`;
  concrete provider deployments live behind it.)
  """
  use AiroWeb, :controller

  alias Airo.Config
  alias Airo.Config.ClientKey

  def index(conn, _params) do
    client_key = conn.assigns.client_key

    data =
      Config.list_aliases()
      |> Enum.filter(&ClientKey.scoped?(client_key, &1.name))
      |> Enum.map(&model_entry/1)

    json(conn, %{"object" => "list", "data" => data})
  end

  defp model_entry(alias_) do
    %{
      "id" => alias_.name,
      "object" => "model",
      "created" => 0,
      "owned_by" => "airo"
    }
  end
end
