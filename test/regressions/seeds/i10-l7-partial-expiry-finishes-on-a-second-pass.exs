%{
  invariant: "I10",
  name: "seed for I10: a partial expiry finishes on a second pass under a fresh reference (L7)",
  seed: 0,
  elixir: "1.20.1",
  otp: "29",
  postgres: "16.13",
  tolerance: 0,
  base_instant: ~U[2026-01-01 00:00:00Z],
  # The first pass takes only the unreserved part and leaves `expired_at` unset
  # (`ledger.ex:299-323`); the second finishes the grant once the hold is gone.
  # The two passes cannot share a reference, because the `(kind, reference)`
  # index would refuse the second, so a partial expiry appends
  # `System.unique_integer/1` (`ledger.ex:356-357`) and is therefore not
  # idempotent: a redelivered partial pass writes a second row. 06a replaces the
  # replay with lot allocations.
  expect: :agreement,
  fixing_unit: "06a",
  expected: %{
    balance: 0,
    held: 0,
    available: 0,
    promotional: 0,
    debt: 0,
    expired: 0
  },
  history: [
    {:grant, "promo", 1_000_000, :promotional, ~U[2026-02-01 00:00:00Z]},
    {:hold, "work", 400_000},
    {:expire_due, ~U[2026-03-01 00:00:00Z]},
    {:release, "work"},
    {:expire_due, ~U[2026-03-01 00:00:00Z]}
  ]
}
