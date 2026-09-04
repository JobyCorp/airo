defmodule Airo.Repo.Migrations.AddRoleToAgents do
  use Ecto.Migration

  @moduledoc """
  S26 — what this airo is *to* the host: `controller` (may load/unload) or
  `observer` (ingests everything, commands nothing). Reported by the agent on
  join and in every register; every existing row is a controller.
  """

  def change do
    alter table(:agents) do
      add :role, :string, null: false, default: "controller"
    end
  end
end
