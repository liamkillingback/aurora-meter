# The fault harness (build unit 01b) starts before the root supervisor, because
# AuroraMeter.Test.Faults must exist before any supervised process can call
# check/2. Its target repo lives under the harness's own application key so the
# library's configuration validation never sees it.
Application.put_env(:aurora_meter_test, :repo, AuroraMeter.TestRepo)

# Start the host-owned processes a real application would provide (repo + pubsub),
# then the Aurora Meter runtime itself.
{:ok, _} =
  Supervisor.start_link(
    [
      AuroraMeter.Test.Faults,
      AuroraMeter.Test.Config,
      AuroraMeter.TestRepo,
      {Phoenix.PubSub, name: AuroraMeter.TestPubSub},
      AuroraMeter
    ],
    strategy: :one_for_one,
    name: AuroraMeter.TestRootSupervisor
  )

Ecto.Adapters.SQL.Sandbox.mode(AuroraMeter.TestRepo, :manual)

# Sweep the non-sandbox tenant prefixes before anything runs (build unit 03e,
# `open-findings.md` X109).
#
# An interruption test cannot guarantee its own teardown by construction: the
# module kills processes, and a test that exits rather than failing an assertion
# can leave `on_exit` unable to take the connection its cleanup needs. That
# would be harmless if tenant keys were unique for ever, but
# `System.unique_integer/1` restarts from small values in every BEAM, so the
# next run reuses the same key and inherits the rows. Measured: 03e's
# correction concurrency file failed once at seed 7 with a totals row holding
# `quantity: 13, events: 6` where it expected `6` and `2`, which is exactly a
# previous run's `10 + 10 - 4 - 9` over four rows added to this run's
# `10 - 4` over two.
#
# The sweep deletes ONLY what these prefixes name (X38: a prefix sweep that
# reaches further deletes rows a concurrent run created), and it runs before
# `ExUnit.start/0` so no test is racing it.
#
# `probe` is here for a reason worth reading (build unit 03d). 03b's
# measurement script `tmp/v1/03b/probe_unresolved.exs` commits two event rows
# under `probe_<n>` with no projection delta, by design: it was measuring
# whether `{:unavailable, :conflict_unresolved}` is reachable. Nothing cleaned
# them up and nothing noticed, because until 03d no test read the whole events
# table and compared it with the whole projection. `AuroraMeter.Events.Replay`
# does exactly that, so those two rows made every `compare: :require_match`
# assertion fail. A probe script that commits rows needs a prefix in this list.
AuroraMeter.Test.Connections.sweep!(~w(
  concurrent corrconc flush_batch gate killt model obansched probe projection
  reconcile recordconc replay replaybig storagecase stmt
))

# The non-prefix half of the same sweep: the projection generation is
# installation-wide, so no `tenant_key LIKE` can put it back.
AuroraMeter.Test.Connections.reset_projection!()

# The ONLY excluded tag in this repository, and it is excluded because the tests
# that carry it assert the ABSENCE of the optional integrations: they are
# meaningless, and would fail, on a build where phoenix_live_view, phoenix_html
# and igniter are present. The `headless` CI leg sets AURORA_HEADLESS=1 and runs
# `mix test --include headless` (build unit 01f, .github/workflows/ci.yml).
#
# :fault and :migration are deliberately NOT here. They have their own CI jobs
# through the `mix v1.faults` and `mix v1.migrations` aliases, and if they were
# excluded by default those jobs would become the only place they ever ran.
# test/aurora_meter/ci_contract_test.exs asserts that this list contains
# neither.
ExUnit.configure(exclude: [:headless])
ExUnit.start()
