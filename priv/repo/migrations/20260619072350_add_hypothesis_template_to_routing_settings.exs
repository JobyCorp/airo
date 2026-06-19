defmodule Airo.Repo.Migrations.AddHypothesisTemplateToRoutingSettings do
  use Ecto.Migration

  @moduledoc "S16 — infinity NLI hypothesis template on the system classifier."

  def up do
    alter table(:routing_settings) do
      add :hypothesis_template, :string, null: false, default: "This request requires {}."
    end

    flush()

    # Backfill from the (single) routed alias's old config, if it set a custom one.
    execute("""
    UPDATE routing_settings
    SET hypothesis_template = COALESCE(
      (SELECT NULLIF(router_config->>'hypothesis_template', '')
         FROM aliases
        WHERE router = 'classify' AND router_config <> '{}'::jsonb
        ORDER BY id LIMIT 1),
      'This request requires {}.'
    )
    """)
  end

  def down do
    alter table(:routing_settings) do
      remove :hypothesis_template
    end
  end
end
