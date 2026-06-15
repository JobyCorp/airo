defmodule Airo.Config.Deployment do
  @moduledoc """
  A concrete `(provider, model)` plus capability, class, and pricing — the
  unit that health and usage attach to (DESIGN §8). Mirrors orchester's
  `CapabilityBinding`. Pricing (`price_input`/`price_output`, per 1k tokens)
  feeds cost attribution on `Airo.Usage.UsageRecord`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.Provider

  @capabilities [:chat, :embeddings, :rerank, :speech, :transcription, :vision, :classify]
  @classes [:edge, :standard, :deep, :cloud]

  @type t :: %__MODULE__{}

  schema "deployments" do
    field :model_name, :string
    field :capability, Ecto.Enum, values: @capabilities
    field :class, Ecto.Enum, values: @classes
    field :tool_use, :boolean, default: false
    field :context_window, :integer
    field :price_input, :decimal
    field :price_output, :decimal
    field :default_params, :map, default: %{}
    field :enabled, :boolean, default: true

    belongs_to :provider, Provider

    timestamps()
  end

  @doc "Enum values for `capability`."
  def capabilities, do: @capabilities

  @doc "Enum values for `class`."
  def classes, do: @classes

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :provider_id,
      :model_name,
      :capability,
      :class,
      :tool_use,
      :context_window,
      :price_input,
      :price_output,
      :default_params,
      :enabled
    ])
    |> validate_required([:provider_id, :model_name, :capability])
    |> validate_number(:context_window, greater_than: 0)
    |> assoc_constraint(:provider)
    |> unique_constraint([:provider_id, :model_name, :capability],
      name: :deployments_provider_id_model_name_capability_index
    )
  end
end
