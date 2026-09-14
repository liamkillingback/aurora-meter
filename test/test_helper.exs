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
