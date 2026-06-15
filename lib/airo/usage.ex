defmodule Airo.Usage do
  @moduledoc """
  Usage + cost attribution (DESIGN §10). Records one `UsageRecord` per gateway
  call. Writes are meant to run off the response path; this context exposes the
  persistence, the async scheduling lives at the call site (S6).
  """
  import Ecto.Query, warn: false

  alias Airo.Repo
  alias Airo.Usage.UsageRecord

  def list_usage_records, do: Repo.all(UsageRecord)

  @doc "Persist a single usage record."
  def record_usage(attrs) do
    %UsageRecord{} |> UsageRecord.changeset(attrs) |> Repo.insert()
  end

  def change_usage_record(%UsageRecord{} = record, attrs \\ %{}),
    do: UsageRecord.changeset(record, attrs)
end
