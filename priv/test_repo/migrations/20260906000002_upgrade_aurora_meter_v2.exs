defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV2 do
  use Ecto.Migration

  def up, do: AuroraMeter.Migration.up(from: 2)
  def down, do: AuroraMeter.Migration.down(to: 2)
end
