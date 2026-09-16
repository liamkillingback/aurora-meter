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
    #
    # **One hour, because sixty seconds was not large enough and the comment
    # above was false.** The core suite takes about 220 seconds, so a sixty
    # second timer fired three or four times in every run at arbitrary points.
    # When one of those points falls inside a module that runs on real
    # connections rather than the sandbox, the Flusher has no connection of its
    # own, the flush raises, and `AuroraMeter.Store.snapshot_flush_batch/0`
    # keeps the batch pending, which is correct (a delta must not be lost) and
    # means the **next** caller's explicit flush persists that stale batch
    # instead of its own counters. The next test then reads `nil` from
    # `Storage.load_counter/3` and fails somewhere unrelated
    # (`open-findings.md` X241, X264). Reproduced deterministically at 120 ms.
    flush_interval: 3_600_000,
    broadcast_interval: 60_000,
    # `0` for the same reason the two above are an hour and a minute, and not
    # because the gauges are unimportant. A gauge tick takes no database
    # connection, so it cannot reproduce X241 directly, but a timer that fires
    # twenty times at arbitrary points in a 220 second run is a telemetry event
    # arriving inside a test that was counting events. The gauge tests set the
    # interval themselves and drive `AuroraMeter.Store.emit_gauge/0` or restart
    # the Store, so the timer is proved deliberately rather than incidentally.
    metrics_interval: 0

  # The OpenTelemetry SDK is an `only: :test` dependency of this repository and
  # of nobody else: it exists so `AuroraMeter.OpenTelemetrySdkTest` can assert
  # the span shape against a real tracer provider rather than against this
  # package's own `AuroraMeter.OpenTelemetry.Tracer` seam.
  #
  # `simple` rather than the default `batch`, because a batch processor exports
  # on a timer and a test would be asserting on a race. `traces_exporter: :none`
  # because the test redirects the processor to `:otel_exporter_pid` itself: the
  # pid is the test process and is not knowable here. **Nothing leaves the
  # node** in either configuration.
  # Guarded by the same switch `mix.exs` uses: with AURORA_NO_OTEL=1 the
  # application is not in the build at all, and Mix warns about configuring one
  # that is not there. A configuration block and the dependency it configures
  # have to be removed by the same switch.
  if System.get_env("AURORA_NO_OTEL") != "1" do
    config :opentelemetry,
      span_processor: :simple,
      traces_exporter: :none
  end

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
