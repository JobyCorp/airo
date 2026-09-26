defmodule Airo.Repo.Migrations.AddAffinityToUsageRecords do
  use Ecto.Migration

  # Session-affinity outcome per request (S29): assigned | hit | reassigned |
  # none. Nullable — error rows and rows written before S29 carry none.
  def change do
    alter table(:usage_records) do
      add :affinity, :string
    end
  end
end
