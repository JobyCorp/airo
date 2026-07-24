defmodule Airo.Repo.Migrations.CreateLaunchProfiles do
  use Ecto.Migration

  def change do
    create table(:launch_profiles) do
      add :model_name, :string, null: false
      add :profile, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:launch_profiles, [:model_name])
  end
end
