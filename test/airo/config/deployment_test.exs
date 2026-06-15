defmodule Airo.Config.DeploymentTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.Deployment

  setup do
    {:ok, provider} =
      Config.create_provider(%{
        name: "local-vllm",
        adapter_type: :vllm,
        base_url: "http://localhost:8000/v1"
      })

    %{provider: provider}
  end

  defp valid(provider),
    do: %{provider_id: provider.id, model_name: "qwen3.5-9b", capability: :chat}

  describe "changeset/2" do
    test "is valid with required fields", %{provider: provider} do
      assert Deployment.changeset(%Deployment{}, valid(provider)).valid?
    end

    test "requires provider_id, model_name, and capability" do
      errors = errors_on(Deployment.changeset(%Deployment{}, %{}))
      assert "can't be blank" in errors.provider_id
      assert "can't be blank" in errors.model_name
      assert "can't be blank" in errors.capability
    end

    test "rejects an unknown capability", %{provider: provider} do
      changeset = Deployment.changeset(%Deployment{}, %{valid(provider) | capability: :vision})
      assert "is invalid" in errors_on(changeset).capability
    end

    test "rejects an unknown class", %{provider: provider} do
      changeset = Deployment.changeset(%Deployment{}, Map.put(valid(provider), :class, :gpu))
      assert "is invalid" in errors_on(changeset).class
    end

    test "rejects a non-positive context_window", %{provider: provider} do
      changeset =
        Deployment.changeset(%Deployment{}, Map.put(valid(provider), :context_window, 0))

      assert "must be greater than 0" in errors_on(changeset).context_window
    end
  end

  describe "uniqueness" do
    test "(provider, model, capability) must be unique", %{provider: provider} do
      assert {:ok, _} = Config.create_deployment(valid(provider))
      assert {:error, changeset} = Config.create_deployment(valid(provider))
      refute changeset.valid?
    end

    test "same model under a different capability is allowed", %{provider: provider} do
      assert {:ok, _} = Config.create_deployment(valid(provider))
      assert {:ok, _} = Config.create_deployment(%{valid(provider) | capability: :embeddings})
    end
  end
end
