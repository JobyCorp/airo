defmodule Airo.Repo.Migrations.AddAgentStaleAfterToSiteSettings do
  use Ecto.Migration

  @moduledoc """
  S25 — how long a *connected* host may go without a register before Airo calls
  it stale. A setting, not a module attribute, for the same reason as
  `down_after_failures` (S24): it is tuned against the operator's own fleet.
  """

  def change do
    alter table(:site_settings) do
      add :agent_stale_after_ms, :integer, null: false, default: 45_000
    end
  end
end
