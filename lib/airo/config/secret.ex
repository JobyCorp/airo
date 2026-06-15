defmodule Airo.Config.Secret do
  @moduledoc """
  Cloak-encrypted secret material referenced by a `Airo.Config.Provider`.

  Holds either a plain API key (`kind: :api_key`) or an OAuth credential
  (`kind: :oauth`, where `value` is the access token and `refresh_token` /
  `expires_at` drive refresh). All token material is encrypted at rest via
  `Airo.Encrypted.Binary`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:api_key, :oauth]

  @type t :: %__MODULE__{}

  schema "secrets" do
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :value, Airo.Encrypted.Binary
    field :refresh_token, Airo.Encrypted.Binary
    field :expires_at, :utc_datetime

    timestamps()
  end

  @doc "Enum values for `kind`, exposed for callers and tests."
  def kinds, do: @kinds

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:name, :kind, :value, :refresh_token, :expires_at])
    |> validate_required([:name, :kind, :value])
    |> unique_constraint(:name)
  end
end
