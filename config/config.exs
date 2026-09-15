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
    # DB_HOST as well as DB_PORT, so the suite can run inside a devcontainer
    # where Postgres is a sibling service rather than localhost.
    hostname: System.get_env("DB_HOST") || "localhost",
    port: String.to_integer(System.get_env("DB_PORT") || "5490"),
    database: "aurora_meter_test",
    pool: Ecto.Adapters.SQL.Sandbox,
    # 60: the credit lot concurrency test opens **50** real (non-sandbox)
    # connections at once, which is what G06 bullet 2 and 06a's acceptance
    # criterion ask for by name, plus the rendezvous holder and the test's own.
    # Fifty tasks queueing for a smaller pool would still all commit, but they
    # would not all be in the database at the same time and the claim is about
    # the lock rather than about the arithmetic. Postgres's default
    # `max_connections` is 100, so this leaves room for the migration harness's
    # own small pools beside it.
    pool_size: 60
end
