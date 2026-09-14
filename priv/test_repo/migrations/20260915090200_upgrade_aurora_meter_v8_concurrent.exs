defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV8Concurrent do
  use Ecto.Migration

  # Core 8 creates a unique index CONCURRENTLY, which Postgres refuses inside a
  # transaction block, and `CREATE INDEX CONCURRENTLY` cannot hold the Ecto
  # migration lock either. Both attributes are required, and this file exists
  # separately from the version 7 one for exactly that reason.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: AuroraMeter.Migration.up(from: 8, version: 8)
  def down, do: AuroraMeter.Migration.down(version: 8, to: 8)
end
