defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV7 do
  use Ecto.Migration

  # Core 7: durable event identity, the projection totals table and the
  # checkpoints table. Additive and transactional.
  def up, do: AuroraMeter.Migration.up(from: 7, version: 7)
  def down, do: AuroraMeter.Migration.down(version: 7, to: 7, confirm_data_loss: true)
end
