defmodule Airo.Logs.LogEvent do
  @moduledoc """
  A persisted operational event (DESIGN-logging-traceability.md §3) — the rows the
  `/admin/logs` timeline reads. Append-only audit/calibration signal, distinct from
  `usage_records` (consumption). `data` carries kind-specific fields:

    - `:route_prediction` — `predicted_class`, `scores`, `mode`, `applied`, `latency_ms`
    - `:health` — `status`, `source`, `reason`, `latency_ms`

  Correlate a request across surfaces via `trace_id`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.{Deployment, Provider}

  @kinds [:route_prediction, :health]
  @levels [:info, :warning, :error]

  @type t :: %__MODULE__{}

  schema "log_events" do
    field :kind, Ecto.Enum, values: @kinds
    field :level, Ecto.Enum, values: @levels, default: :info
    field :trace_id, :string
    field :summary, :string
    field :data, :map, default: %{}
    field :alias_name, :string

    belongs_to :provider, Provider
    belongs_to :deployment, Deployment

    timestamps(updated_at: false)
  end

  def kinds, do: @kinds
  def levels, do: @levels

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :kind,
      :level,
      :trace_id,
      :summary,
      :data,
      :alias_name,
      :provider_id,
      :deployment_id
    ])
    |> validate_required([:kind, :level, :summary])
    |> assoc_constraint(:provider)
    |> assoc_constraint(:deployment)
  end
end
