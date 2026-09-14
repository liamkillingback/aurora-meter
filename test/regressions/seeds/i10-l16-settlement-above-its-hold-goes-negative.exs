%{
  invariant: "I10",
  name: "seed for I10: a settlement above its hold takes the balance negative (L16)",
  seed: 0,
  elixir: "1.20.1",
  otp: "29",
  postgres: "16.13",
  tolerance: 0,
  base_instant: ~U[2026-01-01 00:00:00Z],
  # `settle/3` never refuses for want of credit (`credits.ex:320-323`): the work
  # is done and the cost is real, so the honest record is a negative balance.
  # Today the only signal is `overrun: true` in telemetry metadata
  # (`ledger.ex:167`); nothing in the wallet distinguishes an overrun from a
  # tenant who was simply allowed to go negative. 06a records it as explicit
  # `debt`.
  expect: :agreement,
  fixing_unit: "06a",
  expected: %{
    balance: -500_000,
    held: 0,
    available: -500_000,
    promotional: 0,
    debt: 0,
    expired: 0
  },
  history: [
    {:grant, "topup", 1_000_000, :paid, nil},
    {:hold, "job", 1_000_000},
    {:settle, "job", 1_500_000}
  ]
}
