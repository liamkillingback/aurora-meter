defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV5 do
  use Ecto.Migration

  # Core 5: the partial index behind the open-hold sweep.
  def up, do: AuroraMeter.Migration.up(from: 5, version: 5)
  def down, do: AuroraMeter.Migration.down(version: 5, to: 5)
end
