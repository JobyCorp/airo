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

  @type t :: %__MODULE__{}

  schema "aliases" do
    field :name, :string
    field :capability, Ecto.Enum, values: @capabilities
    field :strategy, Ecto.Enum, values: @strategies, default: :priority
    field :fallback, {:array, :string}, default: []
    field :default_params, :map, default: %{}

    # Optional classification-driven routing (DESIGN-chat-routing.md). `:none`
    # behaves as an ordinary priority alias; `:classify` computes `route.class`
    # from the prompt via the classifier named in `router_config`.
    field :router, Ecto.Enum, values: @routers, default: :none
    field :router_config, :map, default: %{}

    has_many :candidates, AliasCandidate, on_replace: :delete

    timestamps()
  end

  @doc "Enum values for `capability`."
  def capabilities, do: @capabilities

  @doc "Enum values for `strategy`."
  def strategies, do: @strategies

  @doc "Enum values for `router`."
  def routers, do: @routers

  def changeset(alias_, attrs) do
    alias_
    |> cast(attrs, [
      :name,
      :capability,
      :strategy,
      :fallback,
      :default_params,
      :router,
      :router_config
    ])
    |> validate_required([:name, :capability, :strategy])
    |> validate_router_config()
    |> cast_assoc(:candidates)
    |> unique_constraint(:name)
  end

  # A routed alias needs a config to consult; the classifier owns deep validation
  # of its contents (labels, thresholds, classifier name) — here we only ensure
  # there's something non-empty to parse.
  defp validate_router_config(changeset) do
    case get_field(changeset, :router) do
      :classify ->
        case get_field(changeset, :router_config) do
          config when is_map(config) and map_size(config) > 0 -> changeset
          _ -> add_error(changeset, :router_config, "can't be empty when router is :classify")
        end

      _ ->
        changeset
    end
  end
end
