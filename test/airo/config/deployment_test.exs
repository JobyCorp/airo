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
    do: %{provider_id: provider.id, model_name: "qwen3.5-9b", capabilities: [:chat]}

  describe "changeset/2" do
    test "is valid with required fields", %{provider: provider} do
      assert Deployment.changeset(%Deployment{}, valid(provider)).valid?
    end

    test "accepts multiple capabilities", %{provider: provider} do
      changeset =
        Deployment.changeset(%Deployment{}, %{valid(provider) | capabilities: [:chat, :vision]})

      assert changeset.valid?
    end

    test "requires provider_id, model_name, and capabilities" do
      errors = errors_on(Deployment.changeset(%Deployment{}, %{}))
      assert "can't be blank" in errors.provider_id
      assert "can't be blank" in errors.model_name
      assert "can't be blank" in errors.capabilities
    end

    test "rejects empty capabilities", %{provider: provider} do
      changeset = Deployment.changeset(%Deployment{}, %{valid(provider) | capabilities: []})
      assert "should have at least 1 item(s)" in errors_on(changeset).capabilities
    end

    test "rejects an unknown capability", %{provider: provider} do
      changeset =
        Deployment.changeset(%Deployment{}, %{valid(provider) | capabilities: [:nonsense]})

      assert "is invalid" in errors_on(changeset).capabilities
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
    test "(provider, model) must be unique", %{provider: provider} do
      assert {:ok, _} = Config.create_deployment(valid(provider))
      assert {:error, changeset} = Config.create_deployment(valid(provider))
      refute changeset.valid?
    end

    test "the same model is one row carrying many capabilities, not many rows", %{
      provider: provider
    } do
      assert {:ok, _} = Config.create_deployment(valid(provider))

      assert {:error, _} =
               Config.create_deployment(%{valid(provider) | capabilities: [:embeddings]})
    end
  end
end
