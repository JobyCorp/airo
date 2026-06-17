defmodule Airo.Repo.Migrations.AddErrorFieldsToUsageRecords do
  use Ecto.Migration

  def change do
    alter table(:usage_records) do
      add :request_model, :string
      add :error_code, :string
      add :http_status, :integer
      add :upstream_status, :integer
    end

    create index(:usage_records, [:outcome, :inserted_at])
    create index(:usage_records, [:error_code])
  end
end
