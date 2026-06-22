defmodule Airo.Repo.Migrations.CreateAgentsAndLinkProviders do
  use Ecto.Migration

  # Model 2: a host-side control agent is a first-class entity that *manages*
  # providers (it is not itself one). Providers gain a nullable agent_id — set ⇒
  # agent-managed (lifecycle driven by the agent), null ⇒ external/static.
  def change do
    create table(:agents) do
      add :host_id, :string, null: false
      add :control_url, :string, null: false
      add :version, :string
      add :enabled, :boolean, null: false, default: true
      add :last_seen_at, :utc_datetime
      add :gpu, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:agents, [:host_id])

    alter table(:providers) do
      add :agent_id, references(:agents, on_delete: :nilify_all)
    end

    create index(:providers, [:agent_id])
  end
end
