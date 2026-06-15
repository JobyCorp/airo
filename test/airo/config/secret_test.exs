defmodule Airo.Config.SecretTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.Secret

  @valid %{name: "openai-key", kind: :api_key, value: "sk-secret-value"}

  describe "changeset/2" do
    test "is valid with required fields" do
      assert Secret.changeset(%Secret{}, @valid).valid?
    end

    test "requires name, kind, and value" do
      changeset = Secret.changeset(%Secret{}, %{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.kind
      assert "can't be blank" in errors.value
    end

    test "rejects an unknown kind" do
      changeset = Secret.changeset(%Secret{}, %{@valid | kind: :totp})
      assert "is invalid" in errors_on(changeset).kind
    end

    test "accepts every declared kind" do
      for kind <- Secret.kinds() do
        assert Secret.changeset(%Secret{}, %{@valid | kind: kind}).valid?
      end
    end
  end

  describe "encryption at rest" do
    test "value is decrypted on load but ciphertext in the raw column" do
      {:ok, secret} = Config.create_secret(@valid)

      assert Config.get_secret!(secret.id).value == "sk-secret-value"

      %{rows: [[raw]]} =
        Repo.query!("SELECT value FROM secrets WHERE id = $1", [secret.id])

      refute raw == "sk-secret-value"
      refute String.contains?(raw, "sk-secret-value")
    end
  end

  describe "uniqueness" do
    test "name must be unique" do
      assert {:ok, _} = Config.create_secret(@valid)
      assert {:error, changeset} = Config.create_secret(@valid)
      assert "has already been taken" in errors_on(changeset).name
    end
  end
end
