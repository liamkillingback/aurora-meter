# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Everything from `repo:` to `feature_sources:` was written by
# `mix aurora_meter.install --repo AuroraMeterExampleAi.Repo --feature-policy deny
#  --events-source tokens:events`. The four keys after it are the sample's own.
config :aurora_meter,
  repo: AuroraMeterExampleAi.Repo,
  pubsub: AuroraMeterExampleAi.PubSub,
  plans: AuroraMeterExampleAi.Plans,
  undeclared_feature_policy: :deny,
  feature_sources: %{tokens: :events},
  # Without this, a tenant struct would reach `AuroraMeter.Tenant.Default`,
  # which calls `to_string/1` on whatever it is given.
  tenant: AuroraMeterExampleAi.Tenancy,
  # Every organisation starts on `:free` without anyone subscribing it.
  default_plan: :free,
  # The host-owned outbox, called inside the transaction that writes each
  # durable event.
  events_outbox: AuroraMeterExampleAi.SampleOutbox,
  # Below this many micro-dollars available, the credits broadcast carries a
  # low-balance flag and the UI shows a banner. Fifty cents.
  credits_low_balance_threshold: 500_000

config :aurora_meter_example_ai, :scopes,
  user: [
    default: true,
    module: AuroraMeterExampleAi.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: AuroraMeterExampleAi.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :aurora_meter_example_ai,
  ecto_repos: [AuroraMeterExampleAi.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :aurora_meter_example_ai, AuroraMeterExampleAiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AuroraMeterExampleAiWeb.ErrorHTML, json: AuroraMeterExampleAiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AuroraMeterExampleAi.PubSub,
  live_view: [signing_salt: "Yg0+FY3e"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :aurora_meter_example_ai, AuroraMeterExampleAi.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  aurora_meter_example_ai: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  aurora_meter_example_ai: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
