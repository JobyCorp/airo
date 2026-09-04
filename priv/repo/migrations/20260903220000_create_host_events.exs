defmodule Airo.Repo.Migrations.CreateHostEvents do
  use Ecto.Migration

  @moduledoc """
  S25 — host lifecycle history, shaped like `health_events`: insert-only rows
  recording when an agent host connected, dropped, went silent, or changed its
  identity, so "when did sparky last disconnect and for how long" has an answer.

  `agent_id` is nullable: a host can connect before its `agents` row exists
  (the row is created by the first `register`, which follows the join).
  """

  def change do
    create table(:host_events) do
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :host_id, :string, null: false
      add :kind, :string, null: false
      add :reason, :string
      add :meta, :map, null: false, default: %{}

      timestamps(updated_at: false)
    end

    create index(:host_events, [:host_id, :inserted_at])
    create index(:host_events, [:inserted_at])
  end
end
