%{
  invariant: "I10",
  name:
    "seed for I10: a released reservation on a partially expired grant becomes spendable again (L1)",
  seed: 0,
  elixir: "1.20.1",
  otp: "29",
  postgres: "16.13",
  tolerance: 0,
  base_instant: ~U[2026-01-01 00:00:00Z],
  # The expiry could only take what no hold had reserved (`ledger.ex:296-298`),
  # so $0.40 stayed behind with the grant left unstamped. Releasing the hold
  # hands that $0.40 straight back as spendable balance, and it stays spendable
  # until some later `expire_due/1` pass reclaims it. 06a's lot engine writes it
  # off as `expired` instead; `LedgerModel.lot_view/1` measures the difference.
  expect: :agreement,
  fixing_unit: "06a",
  expected: %{
    balance: 400_000,
    held: 0,
    available: 400_000,
    promotional: 400_000,
    debt: 0,
    expired: 0
  },
  history: [
    {:grant, "promo", 1_000_000, :promotional, ~U[2026-02-01 00:00:00Z]},
    {:hold, "work", 400_000},
    {:expire_due, ~U[2026-03-01 00:00:00Z]},
    {:release, "work"}
  ]
}
