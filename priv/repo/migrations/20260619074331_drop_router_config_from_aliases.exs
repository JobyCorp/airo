defmodule Airo.Repo.Migrations.DropRouterConfigFromAliases do
  use Ecto.Migration

  @moduledoc "S16 — the classifier config now lives in routing_settings (T1/T2)."

  def change do
    alter table(:aliases) do
      remove :router_config, :map, default: %{}
    end
  end
end
