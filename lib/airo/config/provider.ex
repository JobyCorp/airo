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

  alias Airo.Config.{Agent, Deployment, Secret}

  @adapter_types [
    :vllm,
    :ollama,
    :lmstudio,
    :openai,
    :anthropic,
    :speaches,
    :infinity,
    :unsloth,
    # Host-side control agent (airo_agent): lifecycle-owned, push health via the
    # control channel; serving routed to the engine base_url. Adapter lands in #5.
    :airo_agent
  ]
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
    # Set ⇒ this provider is a serving slot managed by a host agent (Model 2);
    # null ⇒ external/static (vllm/ollama/openai run by someone else).
    belongs_to :agent, Agent
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
      :credential_id,
      :agent_id
    ])
    |> validate_required([:name, :adapter_type, :base_url, :auth_kind])
    |> validate_base_url()
    |> assoc_constraint(:agent)
    |> unique_constraint(:name)
    |> assoc_constraint(:credential)
  end

  # `base_url` must be an absolute http(s) URL. A scheme-less value like
  # "localhost:4000" parses with the host as the scheme and makes Finch raise at
  # request time (DESIGN §14) — reject it here so it never reaches the transport.
  defp validate_base_url(changeset) do
    validate_change(changeset, :base_url, fn :base_url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [base_url: "must be an absolute http(s) URL, e.g. http://localhost:4000"]
      end
    end)
  end
end
