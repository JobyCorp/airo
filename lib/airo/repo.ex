defmodule Airo.Repo do
  use Ecto.Repo,
    otp_app: :airo,
    adapter: Ecto.Adapters.Postgres
end
