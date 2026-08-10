defmodule Airo.Repo.Migrations.IndexUsageRecordsForActivity do
  use Ecto.Migration

  @moduledoc """
  Support `Airo.Serving.deployment_activity/0`, which asks for the newest
  success and newest failure per deployment (`DISTINCT ON (deployment_id,
  outcome) ... ORDER BY deployment_id, outcome, inserted_at DESC`).

  Without a matching index that plans as a seq scan of the whole table plus a
  sort of every non-null-deployment row — on prod, 85k rows scanned and 51k
  sorted (3.5 MB) to return 10. This index lets the DISTINCT ON walk the
  leading edge of each group instead. No behaviour change: the query and its
  answer are identical, it just stops reading the table to get there.
  """

  # Concurrently so it doesn't take a write lock on a table the gateway is
  # inserting into on every call. Requires @disable_ddl_transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists index(:usage_records, [:deployment_id, :outcome, :inserted_at],
                           name: :usage_records_deployment_outcome_inserted_at_index,
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(:usage_records, [:deployment_id, :outcome, :inserted_at],
                     name: :usage_records_deployment_outcome_inserted_at_index,
                     concurrently: true
                   )
  end
end
