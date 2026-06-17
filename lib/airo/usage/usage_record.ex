defmodule Airo.Usage.UsageRecord do
  @moduledoc """
  Per-call usage + cost attribution (DESIGN §8, §10) — incogito's `Runlog`,
  promoted to a first-class gateway concern now that two apps share a pool.

  Writes are intended to be async (off the response path). `alias_name` is a
  denormalized snapshot rather than an FK, since the alias row may change or be
  removed after the call. `cost` is derived from the serving deployment's
  pricing at write time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.{ClientKey, Deployment, Model}

  @capabilities [:chat, :embeddings, :rerank, :speech, :transcription, :vision, :classify]
  @outcomes [:success, :error, :timeout]

  @type t :: %__MODULE__{}

  schema "usage_records" do
    field :trace_id, :string
    field :request_model, :string
    field :model_display_name, :string
    field :model_upstream_id, :string
    field :model_version, :string
    field :model_revision, :string
    field :alias_name, :string
    field :capability, Ecto.Enum, values: @capabilities
    field :tokens_in, :integer, default: 0
    field :tokens_out, :integer, default: 0
    field :latency_ms, :integer
    field :outcome, Ecto.Enum, values: @outcomes
    field :error_code, :string
    field :http_status, :integer
    field :upstream_status, :integer
    field :finish_reason, :string
    field :fallback_used, :boolean, default: false
    field :cost, :decimal

    belongs_to :client_key, ClientKey
    belongs_to :model, Model
    belongs_to :deployment, Deployment

    timestamps()
  end

  @doc "Enum values for `capability`."
  def capabilities, do: @capabilities

  @doc "Enum values for `outcome`."
  def outcomes, do: @outcomes

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :client_key_id,
      :trace_id,
      :request_model,
      :model_id,
      :model_display_name,
      :model_upstream_id,
      :model_version,
      :model_revision,
      :alias_name,
      :deployment_id,
      :capability,
      :tokens_in,
      :tokens_out,
      :latency_ms,
      :outcome,
      :error_code,
      :http_status,
      :upstream_status,
      :finish_reason,
      :fallback_used,
      :cost
    ])
    |> validate_required([:outcome])
    |> validate_number(:tokens_in, greater_than_or_equal_to: 0)
    |> validate_number(:tokens_out, greater_than_or_equal_to: 0)
    |> validate_number(:http_status, greater_than_or_equal_to: 100, less_than: 600)
    |> validate_number(:upstream_status, greater_than_or_equal_to: 100, less_than: 600)
    |> assoc_constraint(:client_key)
    |> assoc_constraint(:model)
    |> assoc_constraint(:deployment)
  end
end
