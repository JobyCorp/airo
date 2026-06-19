defmodule Airo.LogsTest do
  use Airo.DataCase, async: true

  alias Airo.Logs
  alias Airo.Logs.LogEvent

  defp prediction(attrs \\ %{}) do
    Map.merge(
      %{
        kind: :route_prediction,
        level: :info,
        trace_id: "gt_a",
        summary: "predicted=deep",
        alias_name: "chat",
        data: %{"predicted_class" => "deep", "mode" => "shadow"}
      },
      attrs
    )
  end

  describe "record/1 + changeset" do
    test "records a route_prediction event (synchronous in test)" do
      assert :ok = Logs.record(prediction())

      assert [event] = Logs.list()
      assert event.kind == :route_prediction
      assert event.data["predicted_class"] == "deep"
      assert event.trace_id == "gt_a"
    end

    test "requires kind and summary" do
      errors = errors_on(LogEvent.changeset(%LogEvent{}, %{}))
      assert "can't be blank" in errors.kind
      assert "can't be blank" in errors.summary
    end

    test "rejects an unknown kind" do
      changeset = LogEvent.changeset(%LogEvent{}, %{kind: :nope, summary: "x"})
      assert "is invalid" in errors_on(changeset).kind
    end
  end

  describe "list/2 filters" do
    setup do
      :ok = Logs.record(prediction(%{trace_id: "gt_pred", data: %{"predicted_class" => "deep"}}))

      :ok =
        Logs.record(%{
          kind: :health,
          level: :warning,
          trace_id: "gt_health",
          summary: "health down",
          data: %{"status" => "down"}
        })

      :ok
    end

    test "by kind" do
      assert [e] = Logs.list(%{"kind" => "health"}, 100)
      assert e.kind == :health
    end

    test "by level" do
      assert [e] = Logs.list(%{"level" => "warning"}, 100)
      assert e.level == :warning
    end

    test "by predicted_class (jsonb data)" do
      assert [e] = Logs.list(%{"predicted_class" => "deep"}, 100)
      assert e.data["predicted_class"] == "deep"
    end

    test "by trace" do
      assert [e] = Logs.list(%{"trace_id" => "gt_health"}, 100)
      assert e.trace_id == "gt_health"
    end

    test "summary counts levels" do
      assert %{total: 2, warnings: 1, errors: 0} = Logs.summary()
    end
  end

  describe "for_trace/1" do
    test "returns a trace's events oldest-first" do
      :ok = Logs.record(prediction(%{trace_id: "gt_x", summary: "first"}))
      :ok = Logs.record(%{kind: :health, level: :info, trace_id: "gt_x", summary: "second"})
      :ok = Logs.record(prediction(%{trace_id: "gt_y", summary: "other"}))

      assert ["first", "second"] = Enum.map(Logs.for_trace("gt_x"), & &1.summary)
    end
  end

  describe "PruneWorker" do
    test "deletes events older than the retention window" do
      :ok = Logs.record(prediction(%{summary: "old"}))
      [event] = Logs.list()

      old =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-60 * 86_400, :second)
        |> NaiveDateTime.truncate(:second)

      Repo.update_all(from(l in LogEvent, where: l.id == ^event.id), set: [inserted_at: old])

      assert {:ok, 1} = Airo.Logs.PruneWorker.perform(%Oban.Job{})
      assert Logs.list() == []
    end
  end
end
