import Config

config :demo, ecto_repos: [Demo.Repo]

config :demo, Demo.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("DB_PORT") || "5490"),
  database: "aurora_meter_demo",
  pool_size: 5

config :aurora_meter,
  repo: Demo.Repo,
  pubsub: Demo.PubSub,
  plans: Demo.Plans,
  default_plan: :free

config :logger, level: :warning
