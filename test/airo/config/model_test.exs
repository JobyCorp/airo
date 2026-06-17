defmodule Airo.Config.ModelTest do
  use Airo.DataCase, async: true

  alias Airo.Config
  alias Airo.Config.Model

  @valid %{
    display_name: "Qwen 3.5 9B",
    upstream_model_id: "qwen3.5-9b",
    family: "qwen",
    version: "3.5",
    revision: "2026-06",
    quantization: "Q4_K_M",
    size: "9B",
    status: :evaluating,
    notes: "Candidate local reasoning model"
  }

  describe "changeset/2" do
    test "is valid with required fields and metadata" do
      assert Model.changeset(%Model{}, @valid).valid?
    end

    test "requires display_name, upstream_model_id, and status" do
      errors = errors_on(Model.changeset(%Model{}, %{}))
      assert "can't be blank" in errors.display_name
      assert "can't be blank" in errors.upstream_model_id
    end

    test "rejects an unknown status" do
      changeset = Model.changeset(%Model{}, %{@valid | status: :experimental})
      assert "is invalid" in errors_on(changeset).status
    end
  end

  describe "Config model CRUD" do
    test "creates and updates a model" do
      assert {:ok, model} = Config.create_model(@valid)
      assert model.display_name == "Qwen 3.5 9B"

      assert {:ok, updated} = Config.update_model(model, %{status: :preferred})
      assert updated.status == :preferred
    end
  end
end
