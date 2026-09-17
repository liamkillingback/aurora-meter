defmodule AuroraMeterExampleAi.Repo.Migrations.AddAuroraMeterPro do
  use Ecto.Migration

  def up, do: AuroraMeter.Pro.Migration.up(from: 1, version: 11)
  def down, do: AuroraMeter.Pro.Migration.down(version: 11, to: 1)
end
