defmodule Airo.Repo.Migrations.AddRouterToAliases do
  use Ecto.Migration

  def change do
    alter table(:aliases) do
      # Mirrors `strategy` (Ecto.Enum stored as string) and `default_params`
      # (jsonb default {}). Existing rows default to "none" → ordinary priority
      # aliases, so this is non-breaking. See DESIGN-chat-routing.md §3 (T1).
      add :router, :string, null: false, default: "none"
      add :router_config, :map, null: false, default: %{}
    end
  end
end
