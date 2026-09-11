defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV2 do
  use Ecto.Migration

  # Core 2: the history table.
  def up, do: AuroraMeter.Migration.up(from: 2, version: 2)
  def down, do: AuroraMeter.Migration.down(version: 2, to: 2)
end
