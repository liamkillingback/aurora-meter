import Config

if config_env() == :test do
  config :logger, level: :warning

  config :aurora_meter, ecto_repos: [AuroraMeter.TestRepo]

  config :aurora_meter,
    repo: AuroraMeter.TestRepo,
    pubsub: AuroraMeter.TestPubSub,
    plans: AuroraMeter.TestPlans,
    default_plan: :free,
    # Large intervals so the periodic timers never fire mid-suite; metering tests
    # drive Flusher.flush/0 and the broadcaster explicitly for determinism.
    flush_interval: 60_000,
    broadcast_interval: 60_000

  config :aurora_meter, AuroraMeter.TestRepo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    port: String.to_integer(System.get_env("DB_PORT") || "5490"),
    database: "aurora_meter_test",
    pool: Ecto.Adapters.SQL.Sandbox,
    # 30: the credits concurrency test opens 20 real (non-sandbox) connections at once.
    pool_size: 30
end
