%{
  name: "seed for I10: no-expiry history",
  otp: "29",
  elixir: "1.20.1",
  history: [
    {:grant, "g1", 18188285, :promotional, nil},
    {:grant, "g3", 20636640, :adjustment, nil},
    {:grant, "g5", 1, :paid, nil},
    {:hold, "h7", 730667},
    {:debit, "d9", 4405863},
    {:reverse, "v11", 999999},
    {:settle, "h7", 1058255},
    {:settle, "h7", 552722},
    {:release, "h7"},
    {:settle, "h7", 127507},
    {:reverse, "v18", 42037853},
    {:settle, "h7", 92213},
    {:debit, "d21", 1}
  ],
  seed: 20260914,
  expected: %{
    balance: -9677044,
    expired: 0,
    available: -9677044,
    promotional: 0,
    held: 0,
    debt: 0
  },
  base_instant: ~U[2026-01-01 00:00:00Z],
  tolerance: 0,
  problems: ["V4: balance_after 32360809 != -9677044",
   "V7 attribution: g1 model 0 vs Promotions 12724167"],
  invariant: "I10",
  failed_at_step: 11,
  expect: {:disagreement, "unclassified"},
  observed: %{
    balance_row: %{
      balance: -9677044,
      currency: "usd",
      promotional: 0,
      held: 0,
      tenant_key: "model_52610"
    },
    transactions: [
      %{
        reference: "v18",
        kind: :debit,
        amount: -42037853,
        held_delta: 0,
        inserted_at: ~U[2026-09-14 09:53:50.427406Z],
        balance_after: -9677044
      },
      %{
        reference: "g1",
        kind: :grant,
        amount: 18188285,
        held_delta: 0,
        inserted_at: ~U[2026-09-14 09:53:51.373145Z],
        balance_after: 18188285
      },
      %{
        reference: "g3",
        kind: :grant,
        amount: 20636640,
        held_delta: 0,
        inserted_at: ~U[2026-09-14 09:53:51.380166Z],
        balance_after: 38824925
      },
      %{
        reference: "g5",
        kind: :grant,
        amount: 1,
        held_delta: 0,
        inserted_at: ~U[2026-09-14 09:53:51.386581Z],
        balance_after: 38824926
      },
      %{
        reference: "h7",
        kind: :hold,
        amount: 0,
        held_delta: 730667,
        inserted_at: ~U[2026-09-14 09:53:51.392912Z],
        balance_after: 38824926
      },
      %{
        reference: "d9",
        kind: :debit,
        amount: -4405863,
        held_delta: 0,
        inserted_at: ~U[2026-09-14 09:53:51.399502Z],
        balance_after: 34419063
      },
      %{
        reference: "v11",
        kind: :debit,
        amount: -999999,
        held_delta: 0,
        inserted_at: ~U[2026-09-14 09:53:51.405580Z],
        balance_after: 33419064
      },
      %{
        reference: "h7",
        kind: :settle,
        amount: -1058255,
        held_delta: -730667,
        inserted_at: ~U[2026-09-14 09:53:51.411967Z],
        balance_after: 32360809
      }
    ]
  }
}