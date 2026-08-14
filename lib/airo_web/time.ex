defmodule AiroWeb.Time do
  @moduledoc """
  Rendering stored timestamps in the operator's time zone (S24).

  Everything Airo stores is UTC — `inserted_at` columns are Postgres
  `timestamp`, which Ecto loads as `NaiveDateTime` with no zone attached. The
  admin used to print those verbatim through four private `format_at/1` clones,
  so an operator in California read every page seven hours out with nothing on
  screen saying so.

  One function now, reading the zone from `Airo.Config.time_zone/0`
  (`/admin/settings`). The abbreviation is always rendered — an unlabelled
  timestamp is what caused the confusion in the first place, and `PDT` vs `PST`
  is also the visible proof that this is a real IANA conversion rather than a
  fixed offset.
  """

  alias Airo.Config

  @default_format "%b %d  %I:%M:%S %p %Z"

  @doc """
  Format a stored timestamp in the configured zone.

  Accepts the naive UTC values Ecto hands back, an already-zoned `DateTime`,
  and `nil` (rendered as an em dash, matching the rest of the admin).

      format_at(~N[2026-08-13 21:15:40])   #=> "Aug 13  02:15:40 PM PDT"
      format_at(~N[2026-01-15 21:15:40])   #=> "Jan 15  01:15:40 PM PST"
  """
  def format_at(at, format \\ @default_format)

  def format_at(nil, _format), do: "—"

  def format_at(%NaiveDateTime{} = at, format) do
    at
    |> DateTime.from_naive!("Etc/UTC")
    |> format_at(format)
  end

  def format_at(%DateTime{} = at, format) do
    case DateTime.shift_zone(at, Config.time_zone()) do
      {:ok, shifted} ->
        Calendar.strftime(shifted, format)

      # A zone the database can't resolve would otherwise raise on every row.
      # The changeset refuses those, but the setting could predate a dependency
      # change; showing UTC beats a 500.
      {:error, _reason} ->
        Calendar.strftime(at, format)
    end
  end

  def format_at(other, _format), do: to_string(other)

  @doc "The zone currently in use, for labelling a page or a column header."
  def zone, do: Config.time_zone()
end
