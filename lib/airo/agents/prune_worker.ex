defmodule Airo.Agents.PruneWorker do
  @moduledoc """
  Oban job that prunes `HostEvent`s older than the retention window (S25). Same
  shape and default as `Airo.Logs.PruneWorker`:

      config :airo, Airo.Agents.PruneWorker, retention_days: 30
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Airo.Agents.HostEvent
  alias Airo.Repo

  @default_retention_days 30

  @impl Oban.Worker
  def perform(_job) do
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-retention_days() * 86_400, :second)
    {deleted, _} = Repo.delete_all(from e in HostEvent, where: e.inserted_at < ^cutoff)
    {:ok, deleted}
  end

  defp retention_days do
    Application.get_env(:airo, __MODULE__, [])
    |> Keyword.get(:retention_days, @default_retention_days)
  end
end
