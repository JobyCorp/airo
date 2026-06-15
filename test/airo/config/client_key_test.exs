defmodule Airo.Config.ClientKeyTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.ClientKey

  describe "mint_changeset/2" do
    test "generates a raw key and stores only its hash" do
      changeset = ClientKey.mint_changeset(%ClientKey{}, %{name: "orchester"})
      assert changeset.valid?

      minted = Ecto.Changeset.apply_changes(changeset)
      assert String.starts_with?(minted.key, "airo_")
      assert minted.hashed_key == ClientKey.hash_key(minted.key)
      refute minted.hashed_key == minted.key
    end

    test "requires a name" do
      changeset = ClientKey.mint_changeset(%ClientKey{}, %{})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "defaults allowed_aliases to all" do
      minted =
        %ClientKey{}
        |> ClientKey.mint_changeset(%{name: "incogito"})
        |> Ecto.Changeset.apply_changes()

      assert minted.allowed_aliases == ["*"]
    end
  end

  describe "hash_key/1" do
    test "is deterministic and lowercase hex" do
      assert ClientKey.hash_key("airo_abc") == ClientKey.hash_key("airo_abc")
      assert ClientKey.hash_key("airo_abc") =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  describe "minting via the context" do
    test "persists a usable, hash-addressable key" do
      assert {:ok, key} = Config.mint_client_key(%{name: "orchester"})
      assert Config.get_client_key_by_hash(ClientKey.hash_key(key.key)).id == key.id
    end

    test "name must be unique" do
      assert {:ok, _} = Config.mint_client_key(%{name: "orchester"})
      assert {:error, changeset} = Config.mint_client_key(%{name: "orchester"})
      assert "has already been taken" in errors_on(changeset).name
    end
  end
end
