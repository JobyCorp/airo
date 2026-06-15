defmodule Airo.Config.AliasCandidate do
  @moduledoc """
  Join of `Airo.Config.Alias` → `Airo.Config.Deployment` carrying the routing
  `weight` (for `:weighted`) and `priority` (for `:priority`, lower served
  first). One alias fans out to many candidates; routing picks among the
  healthy ones per the alias `strategy`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.{Alias, Deployment}

  @type t :: %__MODULE__{}

  schema "alias_candidates" do
    field :weight, :integer, default: 100
    field :priority, :integer, default: 0

    belongs_to :alias, Alias
    belongs_to :deployment, Deployment

    timestamps()
  end

  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, [:alias_id, :deployment_id, :weight, :priority])
    |> validate_required([:deployment_id, :weight, :priority])
    |> validate_number(:weight, greater_than_or_equal_to: 0)
    |> assoc_constraint(:deployment)
    |> unique_constraint([:alias_id, :deployment_id],
      name: :alias_candidates_alias_id_deployment_id_index
    )
  end
end
