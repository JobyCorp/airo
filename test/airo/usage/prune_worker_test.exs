defmodule Airo.Usage.PruneWorkerTest do
  use Airo.DataCase, async: true

  alias Airo.Repo
  alias Airo.Usage
  alias Airo.Usage.{PruneWorker, UsageRecord}

  test "prunes usage records older than the retention window, keeping recent ones" do
    old =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-100 * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.insert_all(UsageRecord, [
      %{
        capability: :chat,
        outcome: :success,
        tokens_in: 0,
        tokens_out: 0,
        fallback_used: false,
        inserted_at: old,
        updated_at: old
      }
    ])

    {:ok, _recent} = Usage.record_usage(%{capability: :chat, outcome: :success})

    assert {:ok, 1} = PruneWorker.perform(%Oban.Job{})
    assert length(Usage.list_usage_records()) == 1
  end
end
