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
    # **An hour as well, and for a worse reason than the flusher's.** Sixty
    # seconds meant four or five broadcast ticks per run at arbitrary points,
    # and `AuroraMeter.Broadcaster.handle_info(:broadcast, _)` has no rescue: it
    # opens with `AuroraMeter.Counter.touched_keys/0`, which is
    # `:ets.tab2list/1` on a table `AuroraMeter.Store` owns. A tick that lands
    # between a Store kill and its restart raises `:badarg` and the Broadcaster
    # dies.
    #
    # That is fatal rather than untidy, because `AuroraMeter.KillTest` spends
    # the WHOLE of `AuroraMeter.Supervisor`'s restart budget by design and says
    # so in its own moduledoc: three kills, and OTP's default is three restarts
    # in five seconds. A badly timed tick is the **fourth** restart, the
    # supervisor terminates, and every test after it fails, mostly with
    # `ArgumentError` from ETS on tables that no longer exist. Measured: one
    # verification run failed 694 of 2007 with the supervisor `:noproc`, and the
    # same seed passed on the next run, which is what a timer looks like and not
    # what a seed looks like.
    #
    # Forced deterministically in three parts with their controls in
    # `docs/evidence/v1/phase-08/08c-suite-stability.md` (`open-findings.md`
    # X347). This is X241 and X264's fix finished: the same reasoning was
    # applied to `flush_interval` and to `metrics_interval` and this key was
    # left behind.
    broadcast_interval: 3_600_000,
    # `0` for the same reason the two above are an hour, and not
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

  # `mix aurora_meter.bench` (build unit 08c) runs its end-to-end modes against
  # their OWN database, and refuses a repo whose database name does not end in
  # `_bench` or whose pool is the Ecto sandbox. A bench run writes millions of
  # rows, which would make a concurrent `mix test` slow and non-deterministic,
  # and the sandbox's single owned connection is not the pool a real host uses,
  # so a run inside it would be measuring the sandbox.
  #
  # This switch is what makes a bench run possible at all. Without it BOTH
  # guards fire, which is exactly what test/mix/tasks/aurora_meter_bench_test.exs
  # asserts: the guards are only guards if the ordinary configuration trips them.
  bench? = System.get_env("AURORA_BENCH") == "1"

  bench_repo_opts =
    if bench? do
      # No `:pool` key at all, so Ecto uses its ordinary pool. 30 connections,
      # which is what docs/evidence/v1/phase-00/inventory.json records for this
      # package, and the task warns and records `pool_saturated` when --procs
      # exceeds it.
      [database: "aurora_meter_bench", pool_size: 30]
    else
      # 60: the credit lot concurrency test opens **50** real (non-sandbox)
      # connections at once, which is what G06 bullet 2 and 06a's acceptance
      # criterion ask for by name, plus the rendezvous holder and the test's
      # own. Fifty tasks queueing for a smaller pool would still all commit, but
      # they would not all be in the database at the same time and the claim is
      # about the lock rather than about the arithmetic. Postgres's default
      # `max_connections` is 100, so this leaves room for the migration
      # harness's own small pools beside it.
      [database: "aurora_meter_test", pool: Ecto.Adapters.SQL.Sandbox, pool_size: 60]
    end

  # Pointed at the test database with an ordinary pool, and never started. It is
  # the fixture for `mix aurora_meter.bench`'s SECOND end-to-end refusal: the
  # test repo trips the sandbox guard first, so without a pooled repo the
  # database-name guard could never be observed failing. See
  # `AuroraMeter.Test.PooledTestRepo`.
  config :aurora_meter, AuroraMeter.Test.PooledTestRepo,
    username: "postgres",
    password: "postgres",
    hostname: System.get_env("DB_HOST") || "localhost",
    port: String.to_integer(System.get_env("DB_PORT") || "5490"),
    database: "aurora_meter_test",
    pool_size: 2

  # DB_HOST as well as DB_PORT, so the suite can run inside a devcontainer
  # where Postgres is a sibling service rather than localhost.
  config :aurora_meter,
         AuroraMeter.TestRepo,
         [
           username: "postgres",
           password: "postgres",
           hostname: System.get_env("DB_HOST") || "localhost",
           port: String.to_integer(System.get_env("DB_PORT") || "5490")
         ] ++ bench_repo_opts
end
