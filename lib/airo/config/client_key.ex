defmodule Airo.Config.ClientKey do
  @moduledoc """
  Per-consumer authentication (DESIGN §8, §10). Airo issues a high-entropy raw
  key, stores only its SHA-256 hash, and scopes it to `allowed_aliases`
  (`["*"]` = all). The raw key is returned once at creation and never persisted.

  Because keys are high-entropy, SHA-256 is sufficient (no bcrypt); lookups use
  the stored `hashed_key` and constant-time comparison lives at the auth plug.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @key_bytes 32

  schema "client_keys" do
    field :name, :string
    field :hashed_key, :string
    field :allowed_aliases, {:array, :string}, default: ["*"]
    field :enabled, :boolean, default: true

    # Virtual: the raw key, present only when minting a new key.
    field :key, :string, virtual: true

    timestamps()
  end

  @doc """
  Changeset for an existing key (no minting). Use `mint_changeset/2` to create.
  """
  def changeset(client_key, attrs) do
    client_key
    |> cast(attrs, [:name, :allowed_aliases, :enabled])
    |> validate_required([:name, :allowed_aliases])
    |> unique_constraint(:name)
  end

  @doc """
  Changeset for a brand-new key: generates a raw key, exposes it on `:key`
  (virtual, returned once), and stores only its hash in `:hashed_key`.
  """
  def mint_changeset(client_key, attrs) do
    raw = generate_key()

    client_key
    |> cast(attrs, [:name, :allowed_aliases, :enabled])
    |> validate_required([:name, :allowed_aliases])
    |> put_change(:key, raw)
    |> put_change(:hashed_key, hash_key(raw))
    |> unique_constraint(:name)
    |> unique_constraint(:hashed_key)
  end

  @doc "Generate a URL-safe, high-entropy raw client key."
  def generate_key do
    "airo_" <> (@key_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  @doc "SHA-256 hash (lowercase hex) of a raw key, as stored in `hashed_key`."
  def hash_key(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end
end
