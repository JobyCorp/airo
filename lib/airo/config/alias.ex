defmodule Airo.Config.Alias do
  @moduledoc """
  The logical handle consumers name in `model:` (e.g. `"chat-deep"`). Resolves
  through its `candidates` (weighted/prioritized `Airo.Config.Deployment`s) to a
  concrete upstream, with an optional `fallback` chain of other alias names
  (DESIGN §8, §9). Routing policy attaches here; health/usage attach to the
  Deployment.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.AliasCandidate

  @capabilities [:chat, :embeddings, :rerank, :speech, :transcription, :vision, :classify]
  @strategies [:weighted, :priority, :round_robin]

  @type t :: %__MODULE__{}

  schema "aliases" do
    field :name, :string
    field :capability, Ecto.Enum, values: @capabilities
    field :strategy, Ecto.Enum, values: @strategies, default: :priority
    field :fallback, {:array, :string}, default: []
    field :default_params, :map, default: %{}

    has_many :candidates, AliasCandidate, on_replace: :delete

    timestamps()
  end

  @doc "Enum values for `capability`."
  def capabilities, do: @capabilities

  @doc "Enum values for `strategy`."
  def strategies, do: @strategies

  def changeset(alias_, attrs) do
    alias_
    |> cast(attrs, [:name, :capability, :strategy, :fallback, :default_params])
    |> validate_required([:name, :capability, :strategy])
    |> cast_assoc(:candidates)
    |> unique_constraint(:name)
  end
end
