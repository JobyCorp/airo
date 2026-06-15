defmodule Airo.Config.ProviderTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.Provider

  @valid %{name: "local-vllm", adapter_type: :vllm, base_url: "http://localhost:8000/v1"}

  describe "changeset/2" do
    test "is valid with required fields and defaults auth_kind to :none" do
      changeset = Provider.changeset(%Provider{}, @valid)
      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).auth_kind == :none
    end

    test "requires name, adapter_type, and base_url" do
      errors = errors_on(Provider.changeset(%Provider{}, %{}))
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.adapter_type
      assert "can't be blank" in errors.base_url
    end

    test "rejects an unknown adapter_type" do
      changeset = Provider.changeset(%Provider{}, %{@valid | adapter_type: :cohere})
      assert "is invalid" in errors_on(changeset).adapter_type
    end

    test "rejects an unknown auth_kind" do
      changeset = Provider.changeset(%Provider{}, Map.put(@valid, :auth_kind, :basic))
      assert "is invalid" in errors_on(changeset).auth_kind
    end

    test "accepts every declared adapter_type" do
      for type <- Provider.adapter_types() do
        assert Provider.changeset(%Provider{}, %{@valid | adapter_type: type}).valid?
      end
    end
  end

  describe "uniqueness" do
    test "name must be unique" do
      assert {:ok, _} = Config.create_provider(@valid)
      assert {:error, changeset} = Config.create_provider(@valid)
      assert "has already been taken" in errors_on(changeset).name
    end
  end
end
