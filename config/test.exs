import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :airo, Airo.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "airo_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Route all upstream provider HTTP through a Req.Test plug in tests, so adapter
# and controller tests stub responses with `Req.Test.stub(Airo.TestStub, ...)`.
config :airo, Airo.Transport, req_options: [plug: {Req.Test, Airo.TestStub}]

# Cloak vault key for the test env. Static, non-secret.
config :airo, Airo.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("KVplU57km1VxUNxCETOEO6pS2jDhM2t8Rw4U/4s67Ik="),
       iv_length: 12}
  ]

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :airo, AiroWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "aObNEZ4He1SZfQkrnxIp6LPIAMKGlMdhuwaX1YB9bMreU5r5G9VE/AEBq1MsFwkb",
  server: false

# In test we don't send emails
config :airo, Airo.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
