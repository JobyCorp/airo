defmodule Airo.Repo.Migrations.AddModelSnapshotToUsageRecords do
  use Ecto.Migration

  def change do
    alter table(:usage_records) do
      add :model_id, references(:models, on_delete: :nilify_all)
      add :model_display_name, :string
      add :model_upstream_id, :string
      add :model_version, :string
      add :model_revision, :string
    end

    create index(:usage_records, [:model_id])
    create index(:usage_records, [:model_upstream_id])
    create index(:usage_records, [:model_version])

    execute """
            UPDATE usage_records
            SET model_id = models.id,
                model_display_name = models.display_name,
                model_upstream_id = models.upstream_model_id,
                model_version = models.version,
                model_revision = models.revision
            FROM deployments
            JOIN models ON models.id = deployments.model_id
            WHERE usage_records.deployment_id = deployments.id
              AND usage_records.model_id IS NULL
            """,
            """
            UPDATE usage_records
            SET model_id = NULL,
                model_display_name = NULL,
                model_upstream_id = NULL,
                model_version = NULL,
                model_revision = NULL
            """
  end
end
