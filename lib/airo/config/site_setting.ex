defmodule Airo.Config.SiteSetting do
  @moduledoc """
  Site-wide operator preferences (S24). One singleton row, same shape as
  `Airo.Config.RoutingSetting`: read it through `Airo.Config.site_setting/0`,
  edit it at `/admin/settings`.

  These are knobs an operator tunes against *their* deployment, so they live in
  the database and the UI rather than in `config/*.exs` — changing a threshold
  shouldn't need a release.

    * `time_zone` — the IANA zone every admin timestamp renders in. Rows are
      stored as naive UTC; this is purely presentational. Defaults to
      `America/Los_Angeles`.

    * `down_after_failures` — how many consecutive failing observations it takes
      before a deployment is considered down. Health is a *preference* signal
      and the gateway fails over per request, so reacting to a single failure
      bought nothing and cost a great deal of noise: before this existed, one
      slow request or one timed-out probe marked a working model down, and
      something reversed it seconds later. See DESIGN-logging-traceability.md.

    * `agent_stale_after_ms` — how long a *connected* agent host may go without
      a `register` heartbeat before `Airo.Agents.Liveness` calls it stale (S25).
      Presence alone cannot tell a hung agent from a healthy one.

  Enforced as a singleton via a unique `singleton` flag.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @default_time_zone "America/Los_Angeles"
  @default_down_after 3
  @default_agent_stale_after_ms 45_000

  @type t :: %__MODULE__{}

  schema "site_settings" do
    field :time_zone, :string, default: @default_time_zone
    field :down_after_failures, :integer, default: @default_down_after
    field :agent_stale_after_ms, :integer, default: @default_agent_stale_after_ms
    # Singleton guard — always true, unique.
    field :singleton, :boolean, default: true

    timestamps()
  end

  @doc "The zone used when nothing is configured."
  def default_time_zone, do: @default_time_zone

  @doc "The failure threshold used when nothing is configured."
  def default_down_after_failures, do: @default_down_after

  @doc "Silence (ms) a connected host is allowed before it counts as stale, when unconfigured."
  def default_agent_stale_after_ms, do: @default_agent_stale_after_ms

  # A `Calendar.TimeZoneDatabase` isn't required to enumerate its zones, and the
  # installed one doesn't, so the picker is a curated list rather than all ~600
  # IANA names — which is a better control anyway. Validation does *not* use
  # this list (see `validate_time_zone/1`): any zone the database accepts is
  # allowed, so a value set out of band still works and still renders.
  @common_time_zones [
    "America/Los_Angeles",
    "America/Denver",
    "America/Phoenix",
    "America/Chicago",
    "America/New_York",
    "America/Anchorage",
    "Pacific/Honolulu",
    "America/Toronto",
    "America/Mexico_City",
    "America/Sao_Paulo",
    "Etc/UTC",
    "Europe/London",
    "Europe/Dublin",
    "Europe/Lisbon",
    "Europe/Madrid",
    "Europe/Paris",
    "Europe/Berlin",
    "Europe/Amsterdam",
    "Europe/Stockholm",
    "Europe/Warsaw",
    "Europe/Athens",
    "Europe/Moscow",
    "Asia/Jerusalem",
    "Asia/Dubai",
    "Asia/Kolkata",
    "Asia/Bangkok",
    "Asia/Singapore",
    "Asia/Shanghai",
    "Asia/Hong_Kong",
    "Asia/Tokyo",
    "Asia/Seoul",
    "Australia/Perth",
    "Australia/Sydney",
    "Pacific/Auckland"
  ]

  @doc "Zones offered in the picker. Not the set of *valid* zones — see the changeset."
  def time_zone_options, do: @common_time_zones

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:time_zone, :down_after_failures, :agent_stale_after_ms])
    |> validate_required([:time_zone, :down_after_failures, :agent_stale_after_ms])
    |> validate_time_zone()
    # 1 restores the old "react immediately" behaviour, which is a legitimate
    # choice on a LAN where a failure really does mean down. The upper bound is
    # to stop a typo silently disabling health for an hour.
    |> validate_number(:down_after_failures,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 20
    )
    # Two heartbeats is the floor: below that a GC pause on the host reads as an
    # outage. Ten minutes is the ceiling, so a typo can't switch the check off.
    |> validate_number(:agent_stale_after_ms,
      greater_than_or_equal_to: 20_000,
      less_than_or_equal_to: 600_000
    )
    |> put_change(:singleton, true)
    |> unique_constraint(:singleton)
  end

  # A zone the database doesn't know would raise in `shift_zone!/2` on every
  # admin page, so refuse it here rather than at render time. Asks the database
  # the same question the renderer will, instead of checking a list that could
  # disagree with it.
  defp validate_time_zone(changeset) do
    validate_change(changeset, :time_zone, fn :time_zone, zone ->
      case DateTime.shift_zone(DateTime.utc_now(), zone) do
        {:ok, _} -> []
        {:error, _} -> [time_zone: "is not a time zone this server knows"]
      end
    end)
  end
end
