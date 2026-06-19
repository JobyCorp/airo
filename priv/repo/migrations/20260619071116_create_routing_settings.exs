defmodule Airo.Repo.Migrations.CreateRoutingSettings do
  use Ecto.Migration

  @moduledoc """
  S16 — lift the classifier config into a system-level singleton.

  Additive: creates `routing_settings`, seeds it from the (single) routed alias's
  `aliases.router_config`, and adds `aliases.router_mode` (backfilled from
  `router_config["mode"]`). `aliases.router_config` is left in place — it is
  dropped in a follow-up migration once the classifier seam reads the singleton.
  """

  def up do
    create table(:routing_settings) do
      add :backend, :string, null: false, default: "infinity"
      add :classifier, :string
      add :model, :string
      add :score, :map, null: false, default: %{}
      add :labels, {:array, :map}, null: false, default: []
      add :default_class, :string, null: false, default: "edge"
      add :input, :string, null: false, default: "last_user"
      add :timeout_ms, :integer, null: false, default: 200
      add :singleton, :boolean, null: false, default: true

      timestamps()
    end

    # One row only.
    create unique_index(:routing_settings, [:singleton])

    alter table(:aliases) do
      add :router_mode, :string, null: false, default: "shadow"
    end

    flush()

    # Backfill per-alias mode from the old router_config.
    execute("""
    UPDATE aliases
    SET router_mode = COALESCE(NULLIF(router_config->>'mode', ''), 'shadow')
    WHERE router = 'classify'
    """)

    # Seed the singleton from the first routed alias that carries a config.
    execute("""
    INSERT INTO routing_settings
      (backend, classifier, model, score, labels, default_class, input, timeout_ms,
       singleton, inserted_at, updated_at)
    SELECT
      COALESCE(NULLIF(router_config->>'backend', ''), 'infinity'),
      router_config->>'classifier',
      router_config->>'model',
      COALESCE(router_config->'score', '{}'::jsonb),
      COALESCE(ARRAY(SELECT jsonb_array_elements(router_config->'labels')), ARRAY[]::jsonb[]),
      COALESCE(NULLIF(router_config->>'default_class', ''), 'edge'),
      COALESCE(NULLIF(router_config->>'input', ''), 'last_user'),
      COALESCE((router_config->>'timeout_ms')::int, 200),
      true, now(), now()
    FROM aliases
    WHERE router = 'classify' AND router_config <> '{}'::jsonb
    ORDER BY id
    LIMIT 1
    ON CONFLICT (singleton) DO NOTHING
    """)

    # If nothing was routed, seed a sensible default so the UI has a row to edit.
    execute("""
    INSERT INTO routing_settings
      (backend, classifier, model, score, labels, default_class, input, timeout_ms,
       singleton, inserted_at, updated_at)
    SELECT 'infinity', NULL, NULL, '{}'::jsonb,
      ARRAY['{"class": "deep", "min": 0.5}'::jsonb], 'edge', 'last_user', 200,
      true, now(), now()
    WHERE NOT EXISTS (SELECT 1 FROM routing_settings)
    """)
  end

  def down do
    alter table(:aliases) do
      remove :router_mode
    end

    drop table(:routing_settings)
  end
end
