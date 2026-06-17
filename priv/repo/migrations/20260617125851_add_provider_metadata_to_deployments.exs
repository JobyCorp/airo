defmodule Airo.Repo.Migrations.AddProviderMetadataToDeployments do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :provider_metadata, :map, null: false, default: %{}
    end

    create index(:deployments, [:updated_at])
  end
end
