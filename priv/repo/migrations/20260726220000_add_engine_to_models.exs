defmodule Airo.Repo.Migrations.AddEngineToModels do
  use Ecto.Migration

  def change do
    # Which inference engine serves this artifact. A plain string rather than an
    # enum: the agent owns the vocabulary (`llama_cpp`, `vllm`, `tgi` later), and
    # a new backend appearing there must not need a migration here to be
    # reported. Null for external providers, whose engine is the provider's
    # adapter_type instead.
    alter table(:models) do
      add :engine, :string
    end

    create index(:models, [:engine])
  end
end
