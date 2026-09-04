defmodule Airo.Config.Agent do
  @moduledoc """
  A host-side control agent (Model 2) — a per-host control plane that *manages*
  serving providers (the engines) on that host. It is **not** a provider and is
  never on the inference data path; `control_url` is its management API.

  One agent per host (`host_id` is the durable identity). Providers it manages
  link back via `Provider.agent_id`. GPU telemetry and `last_seen_at` are
  refreshed from the agent's channel pushes — Airo uses them as load/evict
  policy input.

  `role` (S26) is what *this* airo is to the host, as the agent reported it:
  `:controller` may load and unload; `:observer` ingests everything the push
  carries and may route to the slots, but commands nothing. One agent has
  exactly one controller and any number of observers; the agent's own config
  is where that is decided (`AIRO_SOCKET_URL` vs `AIRO_OBSERVER_SOCKET_URLS`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.Provider

  @type t :: %__MODULE__{}

  schema "agents" do
    field :host_id, :string
    field :control_url, :string
    field :version, :string
    field :enabled, :boolean, default: true
    field :last_seen_at, :utc_datetime
    field :gpu, :map, default: %{}
    field :role, Ecto.Enum, values: [:controller, :observer], default: :controller

    has_many :providers, Provider

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:host_id, :control_url, :version, :enabled, :last_seen_at, :gpu, :role])
    |> validate_required([:host_id, :control_url])
    |> validate_control_url()
    |> unique_constraint(:host_id)
  end

  # The control URL must be an absolute http(s) URL (same rule as Provider.base_url).
  defp validate_control_url(changeset) do
    validate_change(changeset, :control_url, fn :control_url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [control_url: "must be an absolute http(s) URL, e.g. http://jobycorp:4400"]
      end
    end)
  end
end
