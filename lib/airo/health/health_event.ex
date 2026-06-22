defmodule Airo.Health.HealthEvent do
  @moduledoc """
  Persisted deployment health transition.

  Runtime routing still reads fast ETS health snapshots. This table is the audit
  trail: when an enabled deployment changed effective health, what signal caused
  it, and what short reason/latency was observed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.{Deployment, Provider}

  @statuses [:up, :down, :unknown]
  # :agent — pushed by an airo_agent over the control channel (decision #3).
  @sources [:probe, :dispatch, :agent]

  schema "health_events" do
    field :status, Ecto.Enum, values: @statuses
    field :source, Ecto.Enum, values: @sources
    field :latency_ms, :integer
    field :reason, :string

    belongs_to :provider, Provider
    belongs_to :deployment, Deployment

    timestamps(updated_at: false)
  end

  def statuses, do: @statuses
  def sources, do: @sources

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:provider_id, :deployment_id, :status, :source, :latency_ms, :reason])
    |> validate_required([:status, :source])
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> validate_length(:reason, max: 255)
    |> assoc_constraint(:provider)
    |> assoc_constraint(:deployment)
  end
end
