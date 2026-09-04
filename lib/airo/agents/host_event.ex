defmodule Airo.Agents.HostEvent do
  @moduledoc """
  A persisted host lifecycle transition (S25) — the host-level counterpart of
  `Airo.Health.HealthEvent`. Insert-only; `Airo.Agents.Lifecycle.transition/3`
  is the only writer.

  Kinds:

    * `:connected` / `:disconnected` — the agent's channel joined or left.
    * `:stale` / `:recovered` — connected but silent past the configured
      threshold, and the register that ended the silence.
    * `:version_changed` / `:control_url_changed` — a register carried a
      different agent identity than the row held.

  `meta` carries kind-specific detail (`version`, `control_url`, `from`/`to`
  for a change, `silent_ms` for stale). Heartbeats are **not** events: a
  register that changes nothing writes nothing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Airo.Config.Agent

  @kinds [:connected, :disconnected, :stale, :recovered, :version_changed, :control_url_changed]

  @type t :: %__MODULE__{}

  schema "host_events" do
    field :host_id, :string
    field :kind, Ecto.Enum, values: @kinds
    field :reason, :string
    field :meta, :map, default: %{}

    belongs_to :agent, Agent

    timestamps(updated_at: false)
  end

  def kinds, do: @kinds

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:agent_id, :host_id, :kind, :reason, :meta])
    |> validate_required([:host_id, :kind])
    |> validate_length(:reason, max: 255)
    |> assoc_constraint(:agent)
  end
end
