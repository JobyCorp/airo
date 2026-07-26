defmodule Airo.Repo.Migrations.AddScopesToClientKeys do
  use Ecto.Migration

  def change do
    alter table(:client_keys) do
      add :scopes, {:array, :string}, null: false, default: ["inference"]
    end

    # The management surface groups usage by deployment and reads the newest
    # record per deployment; neither is served by the existing indexes.
    create index(:usage_records, [:deployment_id, :inserted_at])
  end
end
