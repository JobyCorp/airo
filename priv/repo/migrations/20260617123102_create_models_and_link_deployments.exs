defmodule Airo.Repo.Migrations.CreateModelsAndLinkDeployments do
  use Ecto.Migration

  def change do
    create table(:models) do
      add :display_name, :string, null: false
      add :family, :string
      add :upstream_model_id, :string, null: false
      add :version, :string
      add :revision, :string
      add :quantization, :string
      add :size, :string
      add :status, :string, null: false, default: "evaluating"
      add :notes, :text

      timestamps()
    end

    create index(:models, [:upstream_model_id])
    create index(:models, [:family])
    create index(:models, [:status])

    alter table(:deployments) do
      add :model_id, references(:models, on_delete: :nilify_all)
    end

    create index(:deployments, [:model_id])

    execute """
            INSERT INTO models (display_name, upstream_model_id, status, inserted_at, updated_at)
            SELECT DISTINCT model_name, model_name, 'evaluating', NOW(), NOW()
            FROM deployments
            WHERE model_name IS NOT NULL
            """,
            "DELETE FROM models"

    execute """
            UPDATE deployments
            SET model_id = models.id
            FROM models
            WHERE deployments.model_name = models.upstream_model_id
              AND deployments.model_id IS NULL
            """,
            "UPDATE deployments SET model_id = NULL"
  end
end
