defmodule Airo.Config.Deployment do
  @moduledoc """
  A concrete `(provider, model)` plus its capabilities, class, and pricing — the
  unit that health and usage attach to (DESIGN §8). Mirrors orchester's
  `CapabilityBinding`. Pricing (`price_input`/`price_output`, per 1k tokens)
  feeds cost attribution on `Airo.Usage.UsageRecord`.

  `capabilities` is the set of resources this deployment serves — the thing a
  client requests. It is multi-valued because models genuinely are: a multimodal
  chat model serves `[:chat, :vision]`, a vision-only model `[:vision]`. Routing
  filters candidates by membership; the wire protocol (which adapter callback)
  is a separate concern handled in the adapter.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.Provider

  @capabilities [:chat, :embeddings, :rerank, :speech, :transcription, :vision, :classify]
  @classes [:edge, :standard, :deep, :cloud]

  @type t :: %__MODULE__{}

  schema "deployments" do
    field :model_name, :string
    field :capabilities, {:array, Ecto.Enum}, values: @capabilities
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

  @doc "All capability values a deployment may declare."
  def capabilities, do: @capabilities

  @doc "Enum values for `class`."
  def classes, do: @classes

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :provider_id,
      :model_name,
      :capabilities,
      :class,
      :tool_use,
      :context_window,
      :price_input,
      :price_output,
      :default_params,
      :enabled
    ])
    |> validate_required([:provider_id, :model_name, :capabilities])
    |> validate_length(:capabilities, min: 1)
    |> validate_number(:context_window, greater_than: 0)
    |> assoc_constraint(:provider)
    |> unique_constraint([:provider_id, :model_name],
      name: :deployments_provider_id_model_name_index
    )
  end
end
