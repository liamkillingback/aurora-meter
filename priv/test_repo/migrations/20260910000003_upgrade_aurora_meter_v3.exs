defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV3 do
  use Ecto.Migration

  # Core 3: the prepaid credit ledger.
  def up, do: AuroraMeter.Migration.up(from: 3, version: 3)
  def down, do: AuroraMeter.Migration.down(version: 3, to: 3)
end
