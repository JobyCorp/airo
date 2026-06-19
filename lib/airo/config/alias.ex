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
  @routers [:none, :classify]
  @router_modes [:shadow, :enforce]

  @type t :: %__MODULE__{}

  schema "aliases" do
    field :name, :string
    field :capability, Ecto.Enum, values: @capabilities
    field :strategy, Ecto.Enum, values: @strategies, default: :priority
    field :fallback, {:array, :string}, default: []
    field :default_params, :map, default: %{}

    # Classification-driven routing. `:none` behaves as an ordinary priority
    # alias; `:classify` computes `route.class` from the prompt using the
    # **system classifier** (`Airo.Config.RoutingSetting`, S16). `router_mode`
    # controls whether the prediction is applied (`:enforce`) or only logged
    # (`:shadow`).
    field :router, Ecto.Enum, values: @routers, default: :none
    field :router_mode, Ecto.Enum, values: @router_modes, default: :shadow

    has_many :candidates, AliasCandidate, on_replace: :delete

    timestamps()
  end

  @doc "Enum values for `capability`."
  def capabilities, do: @capabilities

  @doc "Enum values for `strategy`."
  def strategies, do: @strategies

  @doc "Enum values for `router`."
  def routers, do: @routers

  @doc "Enum values for `router_mode`."
  def router_modes, do: @router_modes

  def changeset(alias_, attrs) do
    alias_
    |> cast(attrs, [
      :name,
      :capability,
      :strategy,
      :fallback,
      :default_params,
      :router,
      :router_mode
    ])
    |> validate_required([:name, :capability, :strategy])
    |> cast_assoc(:candidates)
    |> unique_constraint(:name)
  end
end
