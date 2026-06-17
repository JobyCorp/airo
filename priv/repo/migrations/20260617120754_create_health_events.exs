defmodule Airo.Repo.Migrations.CreateHealthEvents do
  use Ecto.Migration

  def change do
    create table(:health_events) do
      add :provider_id, references(:providers, on_delete: :nilify_all)
      add :deployment_id, references(:deployments, on_delete: :nilify_all)
      add :status, :string, null: false
      add :source, :string, null: false
      add :latency_ms, :integer
      add :reason, :string

      timestamps(updated_at: false)
    end

    create index(:health_events, [:provider_id])
    create index(:health_events, [:deployment_id])
    create index(:health_events, [:status])
    create index(:health_events, [:inserted_at])
  end
end
