defmodule AuroraMeter.DoctestsTest do
  @moduledoc """
  Build unit 10a, closing `open-findings.md` X237 in its general form.

  X237 was one `iex>` example, on `AuroraMeter.Pro.Export.daily_csv/3`, that no
  `doctest` declaration anywhere referenced. An example nothing runs is prose
  shaped like a proof, and the specific fix (add the one declaration) would have
  left the next one exactly as invisible. `AuroraMeter.ApiInventoryTest`'s A07
  now asks the general question: every module carrying an `iex>` example must be
  named by some `doctest`. This file is where the modules that had no natural
  home are named, and it is why A07 can be green.

  Modules whose examples belong beside a suite that already sets them up keep
  their declaration there (`AuroraMeter.Credits` in `credits_test.exs`,
  `AuroraMeter.Period` in `period_test.exs`, and a dozen more). Nothing is moved
  here that already had a home.

  `async: false` with the shared sandbox, because a handful of these examples
  query the repository.
  """
  use AuroraMeter.DataCase, async: false

  doctest AuroraMeter.Checkpoints
  doctest AuroraMeter.Config
  doctest AuroraMeter.Credits.LotMigration
  doctest AuroraMeter.Events
  doctest AuroraMeter.Events.Backfill
  doctest AuroraMeter.Events.Canonical
  doctest AuroraMeter.Events.Outbox.Noop
  doctest AuroraMeter.LiveDashboard.Auth
  doctest AuroraMeter.Migration
  doctest AuroraMeter.Oban.Retention
  doctest AuroraMeter.OpenTelemetry.Bridge
  doctest AuroraMeter.Schema.CreditAllocation
  doctest AuroraMeter.Schema.CreditLot
  doctest AuroraMeter.Schema.Subscription
  doctest AuroraMeter.Storage
  doctest AuroraMeter.Subscriptions
  doctest AuroraMeter.Telemetry
  doctest AuroraMeter.Telemetry.Metrics
  doctest AuroraMeter.Tenant
end
