defmodule Airo.Repo.Migrations.CreateSiteSettings do
  use Ecto.Migration

  @moduledoc """
  S24 — site-wide operator preferences as a singleton, mirroring
  `routing_settings` (S16).

  Seeds one row so `/admin/settings` always has something to edit and every
  reader has a value without a nil branch.
  """

  def up do
    create table(:site_settings) do
      add :time_zone, :string, null: false, default: "America/Los_Angeles"
      add :down_after_failures, :integer, null: false, default: 3
      add :singleton, :boolean, null: false, default: true

      timestamps()
    end

    # One row only.
    create unique_index(:site_settings, [:singleton])

    flush()

    execute("""
    INSERT INTO site_settings
      (time_zone, down_after_failures, singleton, inserted_at, updated_at)
    VALUES ('America/Los_Angeles', 3, true, now(), now())
    ON CONFLICT (singleton) DO NOTHING
    """)
  end

  def down do
    drop table(:site_settings)
  end
end
