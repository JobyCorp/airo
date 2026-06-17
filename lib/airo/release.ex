defmodule Airo.Release do
  @moduledoc """
  DB release tasks for running in production without Mix installed.

  `bin/deploy.sh` ships a release and runs `bin/migrate`, which calls `migrate/0`
  here so schema changes land on prod without operator action.
  """
  @app :airo

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  # eval-safety: `bin/airo eval` boots without a running code server (OTP 28), so
  # referencing a not-yet-loaded `:airo` module triggers an on-demand load that
  # crashes the VM. `migrate`/`rollback` survive because Ecto preloads its own
  # modules. Keep any tasks added here to raw SQL through the repo — no app
  # schemas, no contexts.

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database.
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
