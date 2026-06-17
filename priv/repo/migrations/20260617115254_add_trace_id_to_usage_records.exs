defmodule Airo.Repo.Migrations.AddTraceIdToUsageRecords do
  use Ecto.Migration

  def change do
    alter table(:usage_records) do
      add :trace_id, :string
    end

    create index(:usage_records, [:trace_id])
  end
end
