defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV9 do
  use Ecto.Migration

  # Core 9: the credit lot engine's tables, the `seq` ordering column on the
  # ledger, and the balance checks. Additive and transactional, and it writes no
  # data: wallets stay on the legacy writer until they are cut over.
  def up, do: AuroraMeter.Migration.up(from: 9, version: 9)
  def down, do: AuroraMeter.Migration.down(version: 9, to: 9, confirm_data_loss: true)
end
