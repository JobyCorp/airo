# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :airo,
  ecto_repos: [Airo.Repo],
  generators: [timestamp_type: :utc_datetime]

# Oban — housekeeping only (UsageRecord + LogEvent + HostEvent prune). Daily cron ~03:00.
config :airo, Oban,
  repo: Airo.Repo,
  queues: [maintenance: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", Airo.Usage.PruneWorker},
       {"15 3 * * *", Airo.Logs.PruneWorker},
       {"30 3 * * *", Airo.Agents.PruneWorker}
     ]}
  ]

# Configure the endpoint
config :airo, AiroWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AiroWeb.ErrorHTML, json: AiroWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Airo.PubSub,
  live_view: [signing_salt: "wT8baKN1"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :airo, Airo.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  airo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  airo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Local ONNX routing classifier (S15) — load the complexity model at boot in
# every environment so the `:ortex` backend can run on CPU. The artifact lives
# under priv/models/ (gitignored, fetched via `mix airo.fetch_model`) and ships
# inside the release; absent ⇒ the holder records :unavailable and routing
# fails open. Override per-env below if a different model set is wanted.
config :airo, Airo.Routing.LocalClassifier, models: ["nvidia-prompt-task-complexity"]

# Time zones. `DateTime.shift_zone/2` needs a real IANA database, and the admin
# renders every stored (UTC) timestamp in the operator's zone.
#
# `tz`, not `tzdata`, which was the ask: tzdata depends on hackney, which pins
# `idna ~> 6.1`, while this project is on idna 7.1 via Mint — the transport
# every gateway request runs through. A clock feature is not worth downgrading
# the HTTP stack. `tz` implements the same `Calendar.TimeZoneDatabase`
# behaviour with no HTTP dependency, and has no background updater to disable
# (its periodic-update module is opt-in and we don't start it), which was the
# other thing we wanted off on a LAN-only box.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
