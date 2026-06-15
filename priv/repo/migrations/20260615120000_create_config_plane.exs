defmodule Airo.Repo.Migrations.CreateConfigPlane do
  use Ecto.Migration

  @moduledoc """
  S0 — the configuration plane both consumer apps converge onto (DESIGN §8).

  Enum-valued columns are plain strings here; validation lives in the
  changesets via `Ecto.Enum`. Health and per-call routing state are runtime
  (ETS/persistent_term), deliberately kept out of these tables.
  """

  def change do
    # Cloak-encrypted secret material: API keys and OAuth tokens.
    create table(:secrets) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :value, :binary, null: false
      add :refresh_token, :binary
      add :expires_at, :utc_datetime

      timestamps()
    end

    create unique_index(:secrets, [:name])

    # Provider — a physical upstream (orchester Install / incogito Connection).
    create table(:providers) do
      add :name, :string, null: false
      add :adapter_type, :string, null: false
      add :base_url, :string, null: false
      add :credential_id, references(:secrets, on_delete: :nilify_all)
      add :auth_kind, :string, null: false, default: "none"
      add :default_params, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:providers, [:name])
    create index(:providers, [:credential_id])

    # Deployment — a concrete (provider, model) + capabilities + pricing.
    create table(:deployments) do
      add :provider_id, references(:providers, on_delete: :delete_all), null: false
      add :model_name, :string, null: false
      add :capability, :string, null: false
      add :class, :string
      add :tool_use, :boolean, null: false, default: false
      add :context_window, :integer
      add :price_input, :decimal
      add :price_output, :decimal
      add :default_params, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:deployments, [:provider_id, :model_name, :capability])

    # Alias — the logical handle consumers call ("chat-deep").
    create table(:aliases) do
      add :name, :string, null: false
      add :capability, :string, null: false
      add :strategy, :string, null: false, default: "priority"
      add :fallback, {:array, :string}, null: false, default: []
      add :default_params, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:aliases, [:name])

    # AliasCandidate — join of Alias → Deployment with routing weight/priority.
    create table(:alias_candidates) do
      add :alias_id, references(:aliases, on_delete: :delete_all), null: false
      add :deployment_id, references(:deployments, on_delete: :delete_all), null: false
      add :weight, :integer, null: false, default: 100
      add :priority, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:alias_candidates, [:alias_id, :deployment_id])
    create index(:alias_candidates, [:deployment_id])

    # ClientKey — per-consumer auth (hashed; raw key shown once at creation).
    create table(:client_keys) do
      add :name, :string, null: false
      add :hashed_key, :string, null: false
      add :allowed_aliases, {:array, :string}, null: false, default: ["*"]
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:client_keys, [:name])
    create unique_index(:client_keys, [:hashed_key])

    # UsageRecord — per-call usage + cost attribution (promoted incogito Runlog).
    # alias_name is a denormalized snapshot (the alias row may later change/vanish).
    create table(:usage_records) do
      add :client_key_id, references(:client_keys, on_delete: :nilify_all)
      add :alias_name, :string
      add :deployment_id, references(:deployments, on_delete: :nilify_all)
      add :capability, :string
      add :tokens_in, :integer, null: false, default: 0
      add :tokens_out, :integer, null: false, default: 0
      add :latency_ms, :integer
      add :outcome, :string
      add :finish_reason, :string
      add :fallback_used, :boolean, null: false, default: false
      add :cost, :decimal

      timestamps()
    end

    create index(:usage_records, [:client_key_id])
    create index(:usage_records, [:deployment_id])
    create index(:usage_records, [:inserted_at])
  end
end
