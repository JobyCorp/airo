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

  alias Airo.Config.{ClientKey, Deployment}

  @capabilities [:chat, :embeddings, :rerank, :speech, :transcription]
  @outcomes [:success, :error, :timeout]

  @type t :: %__MODULE__{}

  schema "usage_records" do
    field :alias_name, :string
    field :capability, Ecto.Enum, values: @capabilities
    field :tokens_in, :integer, default: 0
    field :tokens_out, :integer, default: 0
    field :latency_ms, :integer
    field :outcome, Ecto.Enum, values: @outcomes
    field :finish_reason, :string
    field :fallback_used, :boolean, default: false
    field :cost, :decimal

    belongs_to :client_key, ClientKey
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
      :alias_name,
      :deployment_id,
      :capability,
      :tokens_in,
      :tokens_out,
      :latency_ms,
      :outcome,
      :finish_reason,
      :fallback_used,
      :cost
    ])
    |> validate_required([:capability, :outcome])
    |> validate_number(:tokens_in, greater_than_or_equal_to: 0)
    |> validate_number(:tokens_out, greater_than_or_equal_to: 0)
    |> assoc_constraint(:client_key)
    |> assoc_constraint(:deployment)
  end
end
