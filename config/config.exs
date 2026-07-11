import Config

if config_env() == :test do
  config :aurora_meter, ecto_repos: [AuroraMeter.TestRepo]

  config :aurora_meter,
    repo: AuroraMeter.TestRepo,
    pubsub: AuroraMeter.TestPubSub,
    plans: AuroraMeter.TestPlans,
    default_plan: :free,
    flush_interval: 50,
    broadcast_interval: 20

  config :aurora_meter, AuroraMeter.TestRepo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    port: String.to_integer(System.get_env("DB_PORT") || "5490"),
    database: "aurora_meter_test",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10
end
