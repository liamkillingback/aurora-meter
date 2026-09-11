defmodule AuroraMeter.TestRepo.Migrations.AddAuroraMeter do
  use Ecto.Migration

  # Pinned to version 1. Unpinned, `up()` meant "everything known today", so a
  # database created before version 5 existed and one created after it ran the
  # same migration and ended up with different schemas — which is how the test
  # database came to be missing the open-hold index.
  def up, do: AuroraMeter.Migration.up(from: 1, version: 1)
  def down, do: AuroraMeter.Migration.down(version: 1, to: 1)
end
