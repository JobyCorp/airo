defmodule Airo.Config.Provider do
  @moduledoc """
  A physical upstream — the union of orchester's `Install` and incogito's
  `Connection` (DESIGN §8). `adapter_type` selects the transport/adapter;
  `auth_kind` plus the optional `credential` (a `Airo.Config.Secret`) describe
  how Airo authenticates to it. `default_params` is the lowest layer of the
  `provider < deployment < alias < request` param-resolution stack.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.{Deployment, Secret}

  @adapter_types [:vllm, :ollama, :lmstudio, :openai, :anthropic, :speaches, :infinity]
  @auth_kinds [:none, :api_key, :oauth]

  @type t :: %__MODULE__{}

  schema "providers" do
    field :name, :string
    field :adapter_type, Ecto.Enum, values: @adapter_types
    field :base_url, :string
    field :auth_kind, Ecto.Enum, values: @auth_kinds, default: :none
    field :default_params, :map, default: %{}
    field :enabled, :boolean, default: true

    belongs_to :credential, Secret
    has_many :deployments, Deployment

    timestamps()
  end

  @doc "Enum values for `adapter_type`."
  def adapter_types, do: @adapter_types

  @doc "Enum values for `auth_kind`."
  def auth_kinds, do: @auth_kinds

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :name,
      :adapter_type,
      :base_url,
      :auth_kind,
      :default_params,
      :enabled,
      :credential_id
    ])
    |> validate_required([:name, :adapter_type, :base_url, :auth_kind])
    |> unique_constraint(:name)
    |> assoc_constraint(:credential)
  end
end
