defmodule Airo.Repo.Migrations.CreateLogEvents do
  use Ecto.Migration

  def change do
    create table(:log_events) do
      add :kind, :string, null: false
      add :level, :string, null: false, default: "info"
      add :trace_id, :string
      add :summary, :text, null: false
      add :data, :map, null: false, default: %{}
      add :alias_name, :string
      add :provider_id, references(:providers, on_delete: :nilify_all)
      add :deployment_id, references(:deployments, on_delete: :nilify_all)

      timestamps(updated_at: false)
    end

    create index(:log_events, [:inserted_at])
    create index(:log_events, [:kind])
    create index(:log_events, [:trace_id])
    create index(:log_events, [:level])
  end
end
