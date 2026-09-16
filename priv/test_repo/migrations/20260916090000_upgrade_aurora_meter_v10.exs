defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV10 do
  use Ecto.Migration

  # Core 10: plan version identity. Two new tables, ten columns on
  # `aurora_meter_subscriptions`, and the `clock_timestamp()` default on
  # `aurora_meter_flush_receipts.inserted_at` that lets `flush_batch/3` stop
  # stamping the receipt from the node (open finding X220).
  #
  # Additive and transactional, and it writes no data: the legacy assignment of
  # `plan_version` is `AuroraMeter.Plans.register!/0`'s, because the fingerprint
  # beside it is a digest of the compiled definition.
  def up, do: AuroraMeter.Migration.up(from: 10, version: 10)
  def down, do: AuroraMeter.Migration.down(version: 10, to: 10, confirm_data_loss: true)
end
