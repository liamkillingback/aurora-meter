defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV4 do
  use Ecto.Migration

  # Core 4: promotional_after on the ledger entries.
  def up, do: AuroraMeter.Migration.up(from: 4, version: 4)
  def down, do: AuroraMeter.Migration.down(version: 4, to: 4)
end
