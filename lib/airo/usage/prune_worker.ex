defmodule Airo.Usage.PruneWorker do
  @moduledoc """
  Oban job that prunes `UsageRecord`s older than the retention window (DESIGN
  §6/§13 — housekeeping). Scheduled daily via the Cron plugin; the retention is
  configurable:

      config :airo, Airo.Usage.PruneWorker, retention_days: 90
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Airo.Repo
  alias Airo.Usage.UsageRecord

  @default_retention_days 90

  @impl Oban.Worker
  def perform(_job) do
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-retention_days() * 86_400, :second)
    {deleted, _} = Repo.delete_all(from r in UsageRecord, where: r.inserted_at < ^cutoff)
    {:ok, deleted}
  end

  defp retention_days do
    Application.get_env(:airo, __MODULE__, [])
    |> Keyword.get(:retention_days, @default_retention_days)
  end
end
