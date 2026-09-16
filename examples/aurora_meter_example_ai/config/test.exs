import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :aurora_meter_example_ai, AuroraMeterExampleAi.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DB_HOST") || "localhost",
  # See config/dev.exs: 5490 is the Aurora Meter package's own container.
  port: String.to_integer(System.get_env("DB_PORT") || "5490"),
  database: "aurora_meter_example_ai_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :aurora_meter_example_ai, AuroraMeterExampleAiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "SS0Ps0vNPjRxcpNW18quPJgcOD9Cwcy98OM7kVQzrV3fWIfjKG8EkfUPOz5T12JG",
  server: false

# In test we don't send emails
config :aurora_meter_example_ai, AuroraMeterExampleAi.Mailer, adapter: Swoosh.Adapters.Test

# The sample's own test switches.
config :aurora_meter_example_ai,
  dev_routes: true,
  dev_tools: true,
  # No simulated latency: the suite is not slowed by pretend work.
  workload_micros_per_token: 0,
  # The drainer never ticks on its own. Tests call `Drainer.drain_now/1`, which
  # is the difference between a suite that is deterministic and one that is
  # usually deterministic.
  outbox_interval: 0

# Aurora Meter's periodic timers are set far out for the same reason: a flush
# or a broadcast landing at an arbitrary point in a test run is the commonest
# source of a failure in an unrelated module. Tests drive both explicitly.
config :aurora_meter,
  flush_interval: 3_600_000,
  broadcast_interval: 3_600_000

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
