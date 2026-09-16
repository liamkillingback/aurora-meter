defmodule AuroraMeterExampleAi.Repo.Migrations.AddAuroraMeter do
  use Ecto.Migration

  def up, do: AuroraMeter.Migration.up(from: 1, version: 10, concurrently: false)
  def down, do: AuroraMeter.Migration.down(version: 10, to: 1, confirm_data_loss: true)
end
