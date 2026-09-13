defmodule AuroraMeter.TestRepo.Migrations.UpgradeCoreV6 do
  use Ecto.Migration

  def up, do: AuroraMeter.Migration.up(from: 6, version: 6)
  def down, do: AuroraMeter.Migration.down(version: 6, to: 6)
end
