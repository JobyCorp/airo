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

    test "rejects a base_url with no scheme" do
      changeset = Provider.changeset(%Provider{}, %{@valid | base_url: "localhost:4000"})

      assert "must be an absolute http(s) URL, e.g. http://localhost:4000" in errors_on(changeset).base_url
    end

    test "rejects a non-http scheme" do
      changeset = Provider.changeset(%Provider{}, %{@valid | base_url: "ftp://host:21"})
      refute changeset.valid?
    end

    test "accepts an https base_url" do
      assert Provider.changeset(%Provider{}, %{@valid | base_url: "https://api.example.com/v1"}).valid?
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
