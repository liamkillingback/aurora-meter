defmodule AuroraMeter.TestRepo.Migrations.BackfillAuroraMeterEvents do
  use Ecto.Migration

  alias AuroraMeter.Events.Backfill

  # The step a real upgrade takes between core 7 and core 8, rehearsed here so
  # the test database is built the way a customer's is. It carries no
  # `AuroraMeter.Migration.up(from: n, version: m)` call, so it does not
  # participate in the pinned-range assertion in
  # `test/aurora_meter/migration_test.exs`.
  #
  # Core 8 refuses to run while any event row has a null `event_id`. In the test
  # database there is usually nothing to fill, and the task says so; on a
  # database that has been used, it fills what is there.
  def up do
    flush()
    Backfill.run(repo: repo())
    :ok
  end

  def down, do: :ok
end
