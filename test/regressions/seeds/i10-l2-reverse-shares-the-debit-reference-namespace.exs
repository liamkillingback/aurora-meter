%{
  invariant: "I10",
  name:
    "seed for I10: a reversal is refused because it shares the debit reference namespace (L2)",
  seed: 0,
  elixir: "1.20.1",
  otp: "29",
  postgres: "16.13",
  tolerance: 0,
  base_instant: ~U[2026-01-01 00:00:00Z],
  # `Credits.reverse/4` goes through `Ledger.debit/5` (`credits.ex:329-335`), so
  # it writes a `kind: :debit` row and competes for the same half of the
  # `(kind, reference)` unique index. A host that keys a refund by the same
  # identifier it keyed the charge with gets `:duplicate_reference` and no
  # refund. 06c gives a reversal its own `kind: :reverse`.
  expect: :agreement,
  fixing_unit: "06c",
  expected: %{
    balance: 900_000,
    held: 0,
    available: 900_000,
    promotional: 0,
    debt: 0,
    expired: 0
  },
  history: [
    {:grant, "topup", 1_000_000, :paid, nil},
    {:debit, "order-1", 100_000},
    {:reverse, "order-1", 50_000}
  ]
}
