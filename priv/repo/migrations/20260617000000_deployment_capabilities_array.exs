defmodule Airo.Repo.Migrations.DeploymentCapabilitiesArray do
  @moduledoc """
  Make a deployment's capability multi-valued: `capability` (single) →
  `capabilities` (array). Capability is the resource a client requests, and
  models genuinely serve more than one (multimodal chat = chat + vision).

  Backfills each row from its old single value, then models the known typed
  deployments honestly (moondream = vision-only, the deep qwen = chat + vision),
  and swaps the uniqueness from (provider, model, capability) to (provider,
  model) — one deployment row per physical model.
  """
  use Ecto.Migration

  def up do
    alter table(:deployments) do
      add :capabilities, {:array, :string}, null: false, default: []
    end

    execute "UPDATE deployments SET capabilities = ARRAY[capability]"
    execute "UPDATE deployments SET capabilities = ARRAY['vision'] WHERE capability = 'vision'"

    execute """
    UPDATE deployments SET capabilities = ARRAY['chat','vision']
    WHERE capability = 'chat' AND model_name LIKE 'qwen3.6-35b%'
    """

    drop unique_index(:deployments, [:provider_id, :model_name, :capability],
           name: :deployments_provider_id_model_name_capability_index
         )

    alter table(:deployments) do
      remove :capability
    end

    create unique_index(:deployments, [:provider_id, :model_name],
             name: :deployments_provider_id_model_name_index
           )
  end

  def down do
    drop unique_index(:deployments, [:provider_id, :model_name],
           name: :deployments_provider_id_model_name_index
         )

    alter table(:deployments) do
      add :capability, :string
    end

    # Collapse the set back to a single value (first element) for the old column.
    execute "UPDATE deployments SET capability = capabilities[1]"

    alter table(:deployments) do
      modify :capability, :string, null: false
    end

    create unique_index(:deployments, [:provider_id, :model_name, :capability],
             name: :deployments_provider_id_model_name_capability_index
           )

    alter table(:deployments) do
      remove :capabilities
    end
  end
end
