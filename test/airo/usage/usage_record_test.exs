defmodule Airo.Usage.UsageRecordTest do
  use Airo.DataCase, async: true

  alias Airo.Usage
  alias Airo.Usage.UsageRecord

  @valid %{
    trace_id: "gt_test",
    capability: :chat,
    outcome: :success,
    tokens_in: 12,
    tokens_out: 34
  }

  describe "changeset/2" do
    test "is valid with required fields" do
      assert UsageRecord.changeset(%UsageRecord{}, @valid).valid?
    end

    test "requires outcome" do
      errors = errors_on(UsageRecord.changeset(%UsageRecord{}, %{}))
      assert "can't be blank" in errors.outcome
    end

    test "rejects an unknown outcome" do
      changeset = UsageRecord.changeset(%UsageRecord{}, %{@valid | outcome: :throttled})
      assert "is invalid" in errors_on(changeset).outcome
    end

    test "rejects negative token counts" do
      changeset = UsageRecord.changeset(%UsageRecord{}, %{@valid | tokens_in: -1})
      assert "must be greater than or equal to 0" in errors_on(changeset).tokens_in
    end
  end

  describe "record_usage/1" do
    test "persists a record without requiring a deployment or client key" do
      assert {:ok, record} = Usage.record_usage(@valid)
      assert record.trace_id == "gt_test"
      assert record.alias_name == nil
      assert record.outcome == :success
    end
  end
end
