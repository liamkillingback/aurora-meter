defmodule Demo.Repo.Migrations.AddAuroraMeter do
  use Ecto.Migration

  def up, do: AuroraMeter.Migration.up()
  def down, do: AuroraMeter.Migration.down()
end
