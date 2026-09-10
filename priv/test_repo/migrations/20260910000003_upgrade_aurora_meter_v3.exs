defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV3 do
  use Ecto.Migration

  def up, do: AuroraMeter.Migration.up(from: 3)
  def down, do: AuroraMeter.Migration.down(to: 3)
end
