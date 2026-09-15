%{
  invariant: "I10",
  name: "seed for I10: a reversal and a debit may share one reference string (L2)",
  seed: 0,
  elixir: "1.20.1",
  otp: "29",
  postgres: "16.13",
  tolerance: 0,
  base_instant: ~U[2026-01-01 00:00:00Z],
  # **The after half of finding L2, and the file name says which half it is.**
  #
  # Until build unit 06c, `Credits.reverse/4` went through `Ledger.debit/5` and
  # wrote a `kind: :debit` row, so it competed for the same half of the
  # `(kind, reference)` unique index as an ordinary debit. A host that keyed a
  # refund by the identifier it had keyed the charge with was told
  # `:duplicate_reference` and got no refund, and the recorded balance here was
  # 900_000: the debit landed and the reversal did not.
  #
  # A reversal now writes `kind: :reverse`, so the two references live in
  # different namespaces and both writes land. The balance is 1_000_000 less
  # the 100_000 debit less the 50_000 reversal.
  expect: :agreement,
  fixing_unit: "06c",
  expected: %{
    balance: 850_000,
    held: 0,
    available: 850_000,
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
