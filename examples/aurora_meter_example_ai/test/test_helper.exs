pro? = Code.ensure_loaded?(AuroraMeter.Pro)

pro_files = Path.wildcard(Path.join(__DIR__, "pro/**/*_test.exs"))

if pro? do
  ExUnit.start()
else
  # A skipped required suite is a failure, and the way that failure usually
  # happens is silently: the tag is excluded, ExUnit prints "N excluded" in
  # grey among a row of dots, and a green run means nothing. So the skip says
  # what it is skipping, why, and how to run it, on stderr where a CI log keeps
  # it.
  IO.puts(:stderr, """

  ================================================================
  SKIPPING the Pro profile's tests: #{length(pro_files)} file(s), tagged :pro
  ================================================================

  Aurora Meter Pro is not in this build, so #{length(pro_files)} test file(s)
  under test/pro/ are excluded. They are NOT passing; they did not run.

  #{Enum.map_join(pro_files, "\n", &("  " <> Path.relative_to(&1, __DIR__)))}

  To run them:

      mix hex.organization auth phxtemplates --key "$AURORA_HEX_READ_KEY"
      export AURORA_SAMPLE_PRO=1
      mix deps.get && mix ecto.migrate
      mix ecto.migrate --migrations-path priv/repo/pro_migrations
      mix test

  Everything else in this suite runs in both profiles and asserts the right
  thing in each, which is why there is no other exclusion.
  ================================================================
  """)

  ExUnit.start(exclude: [:pro])
end

Ecto.Adapters.SQL.Sandbox.mode(AuroraMeterExampleAi.Repo, :manual)
