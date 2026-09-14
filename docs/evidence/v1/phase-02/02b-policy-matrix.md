# 02b: the undeclared-feature policy matrix

Gate G02 bullet 1 ("table-driven tests cover every feature kind and unknown-feature
policy across public API entry points"). Build unit 02b, core `aurora_meter`.

## What was measured

8 feature kinds by 4 policy values by 9 entry points = **288 cases**, every one
asserting a value rather than a shape, plus the counter after the call.

| Axis | Values |
|---|---|
| kind | `hard`, `metered`, `counter`, `boolean_true`, `boolean_false`, `integer_value`, `undeclared_anywhere`, `declared_on_another_plan` |
| policy | `:allow`, `:warn`, `:deny`, `:raise` |
| entry point | `check/2`, `allowed?/2`, `entitled?/2`, `feature_value/3`, `quota/2`, `remaining/2`, `reserve/3`, `with_quota/4`, `track/4` |

The plans are `AuroraMeter.Test.PolicyPlans` (`test/support/policy_test_plans.ex`).
Every tenant is subscribed to `:policy`, which declares the six declared kinds.
`:nowhere` is declared by no plan; `:elsewhere` is declared by `:policy_other` and
not by `:policy`, which is the case `:undeclared_feature_policy` exists for.

## Where the numbers come from

Two independent runs, which is deliberate: the expectation table is written out
twice, once in each, so a mistake in one of them shows up as a mismatch rather
than as agreement with itself.

1. `mix test test/aurora_meter/feature_policy_test.exs --seed 0`
   300 passed: 288 generated cases plus 12 named ones (B04 to B07, the two I04
   tests, the `:raise` payload, and the `:not_in_plan` case).
   Log: `tmp/v1/02b/logs/07-policy.log`.
2. `mix run tmp/v1/02b/matrix_report.exs`, outside ExUnit, against a real
   supervision tree and the real repo. It prints the table below and compares
   each observed value with its own copy of the expectations.
   **288 cases, 0 mismatches.** Log: `tmp/v1/02b/logs/22-matrix.log`.

Seed: `0` for the ExUnit run. The matrix script does not randomise: it walks the
three axes in the order above, with a fresh tenant per case.

## Reading the table

`expected` and `observed` are the same column format. `quota` is rendered as its
key/value pairs with `:period` and `:feature` dropped (`:period` is the calendar
month and `:feature` is the row's own feature; neither is policy-dependent).
`counter` is `AuroraMeter.usage/2` for that tenant and feature after the call:
`0` unless the entry point was meant to count. `{:raised, reason}` is an
`AuroraMeter.UndeclaredFeatureError` with that `reason`.

The three things the table proves, read down the columns:

- **B04**: for the six declared kinds, the four policy rows of any one
  `{kind, entry point}` are identical. Policy is not part of the answer.
- **B05**: the shape never changes. `check/2` is always `:ok` or
  `{:error, atom}`, `quota/2` always has the same key set, `remaining/2` is
  always a non-negative integer or `:unlimited`.
- **B07 and I04**: `track/4` counts 3 in every one of its 32 rows, and every
  denied or raised `reserve`/`with_quota` row has a counter of `0`.

## The matrix

| # | kind | policy | entry point | expected | observed | counter | verdict |
|---|---|---|---|---|---|---|---|
| 1 | hard | :allow | check | :ok | :ok | 0 | match |
| 2 | hard | :allow | allowed? | true | true | 0 | match |
| 3 | hard | :allow | entitled? | true | true | 0 | match |
| 4 | hard | :allow | feature_value | :no_value | :no_value | 0 | match |
| 5 | hard | :allow | quota | enabled=true included=50 kind=:hard limit=50 overage=0 percent=0 remaining=50 unit_price=nil used=0 value=nil | enabled=true included=50 kind=:hard limit=50 overage=0 percent=0 remaining=50 unit_price=nil used=0 value=nil | 0 | match |
| 6 | hard | :allow | remaining | 50 | 50 | 0 | match |
| 7 | hard | :allow | reserve | :ok | :ok | 1 | match |
| 8 | hard | :allow | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 9 | hard | :allow | track | :ok | :ok | 3 | match |
| 10 | hard | :warn | check | :ok | :ok | 0 | match |
| 11 | hard | :warn | allowed? | true | true | 0 | match |
| 12 | hard | :warn | entitled? | true | true | 0 | match |
| 13 | hard | :warn | feature_value | :no_value | :no_value | 0 | match |
| 14 | hard | :warn | quota | enabled=true included=50 kind=:hard limit=50 overage=0 percent=0 remaining=50 unit_price=nil used=0 value=nil | enabled=true included=50 kind=:hard limit=50 overage=0 percent=0 remaining=50 unit_price=nil used=0 value=nil | 0 | match |
| 15 | hard | :warn | remaining | 50 | 50 | 0 | match |
| 16 | hard | :warn | reserve | :ok | :ok | 1 | match |
| 17 | hard | :warn | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 18 | hard | :warn | track | :ok | :ok | 3 | match |
| 19 | hard | :deny | check | :ok | :ok | 0 | match |
| 20 | hard | :deny | allowed? | true | true | 0 | match |
| 21 | hard | :deny | entitled? | true | true | 0 | match |
| 22 | hard | :deny | feature_value | :no_value | :no_value | 0 | match |
| 23 | hard | :deny | quota | enabled=true included=50 kind=:hard limit=50 overage=0 percent=0 remaining=50 unit_price=nil used=0 value=nil | enabled=true included=50 kind=:hard limit=50 overage=0 percent=0 remaining=50 unit_price=nil used=0 value=nil | 0 | match |
| 24 | hard | :deny | remaining | 50 | 50 | 0 | match |
| 25 | hard | :deny | reserve | :ok | :ok | 1 | match |
| 26 | hard | :deny | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 27 | hard | :deny | track | :ok | :ok | 3 | match |
| 28 | hard | :raise | check | :ok | :ok | 0 | match |
| 29 | hard | :raise | allowed? | true | true | 0 | match |
| 30 | hard | :raise | entitled? | true | true | 0 | match |
| 31 | hard | :raise | feature_value | :no_value | :no_value | 0 | match |
| 32 | hard | :raise | quota | enabled=true included=50 kind=:hard limit=50 overage=0 percent=0 remaining=50 unit_price=nil used=0 value=nil | enabled=true included=50 kind=:hard limit=50 overage=0 percent=0 remaining=50 unit_price=nil used=0 value=nil | 0 | match |
| 33 | hard | :raise | remaining | 50 | 50 | 0 | match |
| 34 | hard | :raise | reserve | :ok | :ok | 1 | match |
| 35 | hard | :raise | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 36 | hard | :raise | track | :ok | :ok | 3 | match |
| 37 | metered | :allow | check | :ok | :ok | 0 | match |
| 38 | metered | :allow | allowed? | true | true | 0 | match |
| 39 | metered | :allow | entitled? | true | true | 0 | match |
| 40 | metered | :allow | feature_value | :no_value | :no_value | 0 | match |
| 41 | metered | :allow | quota | enabled=true included=100 kind=:metered limit=nil overage=0 percent=0 remaining=:unlimited unit_price=2 used=0 value=nil | enabled=true included=100 kind=:metered limit=nil overage=0 percent=0 remaining=:unlimited unit_price=2 used=0 value=nil | 0 | match |
| 42 | metered | :allow | remaining | :unlimited | :unlimited | 0 | match |
| 43 | metered | :allow | reserve | :ok | :ok | 1 | match |
| 44 | metered | :allow | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 45 | metered | :allow | track | :ok | :ok | 3 | match |
| 46 | metered | :warn | check | :ok | :ok | 0 | match |
| 47 | metered | :warn | allowed? | true | true | 0 | match |
| 48 | metered | :warn | entitled? | true | true | 0 | match |
| 49 | metered | :warn | feature_value | :no_value | :no_value | 0 | match |
| 50 | metered | :warn | quota | enabled=true included=100 kind=:metered limit=nil overage=0 percent=0 remaining=:unlimited unit_price=2 used=0 value=nil | enabled=true included=100 kind=:metered limit=nil overage=0 percent=0 remaining=:unlimited unit_price=2 used=0 value=nil | 0 | match |
| 51 | metered | :warn | remaining | :unlimited | :unlimited | 0 | match |
| 52 | metered | :warn | reserve | :ok | :ok | 1 | match |
| 53 | metered | :warn | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 54 | metered | :warn | track | :ok | :ok | 3 | match |
| 55 | metered | :deny | check | :ok | :ok | 0 | match |
| 56 | metered | :deny | allowed? | true | true | 0 | match |
| 57 | metered | :deny | entitled? | true | true | 0 | match |
| 58 | metered | :deny | feature_value | :no_value | :no_value | 0 | match |
| 59 | metered | :deny | quota | enabled=true included=100 kind=:metered limit=nil overage=0 percent=0 remaining=:unlimited unit_price=2 used=0 value=nil | enabled=true included=100 kind=:metered limit=nil overage=0 percent=0 remaining=:unlimited unit_price=2 used=0 value=nil | 0 | match |
| 60 | metered | :deny | remaining | :unlimited | :unlimited | 0 | match |
| 61 | metered | :deny | reserve | :ok | :ok | 1 | match |
| 62 | metered | :deny | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 63 | metered | :deny | track | :ok | :ok | 3 | match |
| 64 | metered | :raise | check | :ok | :ok | 0 | match |
| 65 | metered | :raise | allowed? | true | true | 0 | match |
| 66 | metered | :raise | entitled? | true | true | 0 | match |
| 67 | metered | :raise | feature_value | :no_value | :no_value | 0 | match |
| 68 | metered | :raise | quota | enabled=true included=100 kind=:metered limit=nil overage=0 percent=0 remaining=:unlimited unit_price=2 used=0 value=nil | enabled=true included=100 kind=:metered limit=nil overage=0 percent=0 remaining=:unlimited unit_price=2 used=0 value=nil | 0 | match |
| 69 | metered | :raise | remaining | :unlimited | :unlimited | 0 | match |
| 70 | metered | :raise | reserve | :ok | :ok | 1 | match |
| 71 | metered | :raise | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 72 | metered | :raise | track | :ok | :ok | 3 | match |
| 73 | counter | :allow | check | :ok | :ok | 0 | match |
| 74 | counter | :allow | allowed? | true | true | 0 | match |
| 75 | counter | :allow | entitled? | true | true | 0 | match |
| 76 | counter | :allow | feature_value | :no_value | :no_value | 0 | match |
| 77 | counter | :allow | quota | enabled=true included=nil kind=:counter limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:counter limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 78 | counter | :allow | remaining | :unlimited | :unlimited | 0 | match |
| 79 | counter | :allow | reserve | :ok | :ok | 1 | match |
| 80 | counter | :allow | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 81 | counter | :allow | track | :ok | :ok | 3 | match |
| 82 | counter | :warn | check | :ok | :ok | 0 | match |
| 83 | counter | :warn | allowed? | true | true | 0 | match |
| 84 | counter | :warn | entitled? | true | true | 0 | match |
| 85 | counter | :warn | feature_value | :no_value | :no_value | 0 | match |
| 86 | counter | :warn | quota | enabled=true included=nil kind=:counter limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:counter limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 87 | counter | :warn | remaining | :unlimited | :unlimited | 0 | match |
| 88 | counter | :warn | reserve | :ok | :ok | 1 | match |
| 89 | counter | :warn | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 90 | counter | :warn | track | :ok | :ok | 3 | match |
| 91 | counter | :deny | check | :ok | :ok | 0 | match |
| 92 | counter | :deny | allowed? | true | true | 0 | match |
| 93 | counter | :deny | entitled? | true | true | 0 | match |
| 94 | counter | :deny | feature_value | :no_value | :no_value | 0 | match |
| 95 | counter | :deny | quota | enabled=true included=nil kind=:counter limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:counter limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 96 | counter | :deny | remaining | :unlimited | :unlimited | 0 | match |
| 97 | counter | :deny | reserve | :ok | :ok | 1 | match |
| 98 | counter | :deny | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 99 | counter | :deny | track | :ok | :ok | 3 | match |
| 100 | counter | :raise | check | :ok | :ok | 0 | match |
| 101 | counter | :raise | allowed? | true | true | 0 | match |
| 102 | counter | :raise | entitled? | true | true | 0 | match |
| 103 | counter | :raise | feature_value | :no_value | :no_value | 0 | match |
| 104 | counter | :raise | quota | enabled=true included=nil kind=:counter limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:counter limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 105 | counter | :raise | remaining | :unlimited | :unlimited | 0 | match |
| 106 | counter | :raise | reserve | :ok | :ok | 1 | match |
| 107 | counter | :raise | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 108 | counter | :raise | track | :ok | :ok | 3 | match |
| 109 | boolean_true | :allow | check | :ok | :ok | 0 | match |
| 110 | boolean_true | :allow | allowed? | true | true | 0 | match |
| 111 | boolean_true | :allow | entitled? | true | true | 0 | match |
| 112 | boolean_true | :allow | feature_value | true | true | 0 | match |
| 113 | boolean_true | :allow | quota | enabled=true included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 114 | boolean_true | :allow | remaining | :unlimited | :unlimited | 0 | match |
| 115 | boolean_true | :allow | reserve | :ok | :ok | 1 | match |
| 116 | boolean_true | :allow | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 117 | boolean_true | :allow | track | :ok | :ok | 3 | match |
| 118 | boolean_true | :warn | check | :ok | :ok | 0 | match |
| 119 | boolean_true | :warn | allowed? | true | true | 0 | match |
| 120 | boolean_true | :warn | entitled? | true | true | 0 | match |
| 121 | boolean_true | :warn | feature_value | true | true | 0 | match |
| 122 | boolean_true | :warn | quota | enabled=true included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 123 | boolean_true | :warn | remaining | :unlimited | :unlimited | 0 | match |
| 124 | boolean_true | :warn | reserve | :ok | :ok | 1 | match |
| 125 | boolean_true | :warn | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 126 | boolean_true | :warn | track | :ok | :ok | 3 | match |
| 127 | boolean_true | :deny | check | :ok | :ok | 0 | match |
| 128 | boolean_true | :deny | allowed? | true | true | 0 | match |
| 129 | boolean_true | :deny | entitled? | true | true | 0 | match |
| 130 | boolean_true | :deny | feature_value | true | true | 0 | match |
| 131 | boolean_true | :deny | quota | enabled=true included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 132 | boolean_true | :deny | remaining | :unlimited | :unlimited | 0 | match |
| 133 | boolean_true | :deny | reserve | :ok | :ok | 1 | match |
| 134 | boolean_true | :deny | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 135 | boolean_true | :deny | track | :ok | :ok | 3 | match |
| 136 | boolean_true | :raise | check | :ok | :ok | 0 | match |
| 137 | boolean_true | :raise | allowed? | true | true | 0 | match |
| 138 | boolean_true | :raise | entitled? | true | true | 0 | match |
| 139 | boolean_true | :raise | feature_value | true | true | 0 | match |
| 140 | boolean_true | :raise | quota | enabled=true included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 141 | boolean_true | :raise | remaining | :unlimited | :unlimited | 0 | match |
| 142 | boolean_true | :raise | reserve | :ok | :ok | 1 | match |
| 143 | boolean_true | :raise | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 144 | boolean_true | :raise | track | :ok | :ok | 3 | match |
| 145 | boolean_false | :allow | check | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 146 | boolean_false | :allow | allowed? | false | false | 0 | match |
| 147 | boolean_false | :allow | entitled? | false | false | 0 | match |
| 148 | boolean_false | :allow | feature_value | false | false | 0 | match |
| 149 | boolean_false | :allow | quota | enabled=false included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=false included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 150 | boolean_false | :allow | remaining | :unlimited | :unlimited | 0 | match |
| 151 | boolean_false | :allow | reserve | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 152 | boolean_false | :allow | with_quota | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 153 | boolean_false | :allow | track | :ok | :ok | 3 | match |
| 154 | boolean_false | :warn | check | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 155 | boolean_false | :warn | allowed? | false | false | 0 | match |
| 156 | boolean_false | :warn | entitled? | false | false | 0 | match |
| 157 | boolean_false | :warn | feature_value | false | false | 0 | match |
| 158 | boolean_false | :warn | quota | enabled=false included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=false included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 159 | boolean_false | :warn | remaining | :unlimited | :unlimited | 0 | match |
| 160 | boolean_false | :warn | reserve | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 161 | boolean_false | :warn | with_quota | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 162 | boolean_false | :warn | track | :ok | :ok | 3 | match |
| 163 | boolean_false | :deny | check | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 164 | boolean_false | :deny | allowed? | false | false | 0 | match |
| 165 | boolean_false | :deny | entitled? | false | false | 0 | match |
| 166 | boolean_false | :deny | feature_value | false | false | 0 | match |
| 167 | boolean_false | :deny | quota | enabled=false included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=false included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 168 | boolean_false | :deny | remaining | :unlimited | :unlimited | 0 | match |
| 169 | boolean_false | :deny | reserve | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 170 | boolean_false | :deny | with_quota | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 171 | boolean_false | :deny | track | :ok | :ok | 3 | match |
| 172 | boolean_false | :raise | check | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 173 | boolean_false | :raise | allowed? | false | false | 0 | match |
| 174 | boolean_false | :raise | entitled? | false | false | 0 | match |
| 175 | boolean_false | :raise | feature_value | false | false | 0 | match |
| 176 | boolean_false | :raise | quota | enabled=false included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=false included=nil kind=:boolean limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 177 | boolean_false | :raise | remaining | :unlimited | :unlimited | 0 | match |
| 178 | boolean_false | :raise | reserve | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 179 | boolean_false | :raise | with_quota | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 180 | boolean_false | :raise | track | :ok | :ok | 3 | match |
| 181 | integer_value | :allow | check | :ok | :ok | 0 | match |
| 182 | integer_value | :allow | allowed? | true | true | 0 | match |
| 183 | integer_value | :allow | entitled? | true | true | 0 | match |
| 184 | integer_value | :allow | feature_value | 7 | 7 | 0 | match |
| 185 | integer_value | :allow | quota | enabled=true included=nil kind=:feature limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=7 | enabled=true included=nil kind=:feature limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=7 | 0 | match |
| 186 | integer_value | :allow | remaining | :unlimited | :unlimited | 0 | match |
| 187 | integer_value | :allow | reserve | :ok | :ok | 1 | match |
| 188 | integer_value | :allow | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 189 | integer_value | :allow | track | :ok | :ok | 3 | match |
| 190 | integer_value | :warn | check | :ok | :ok | 0 | match |
| 191 | integer_value | :warn | allowed? | true | true | 0 | match |
| 192 | integer_value | :warn | entitled? | true | true | 0 | match |
| 193 | integer_value | :warn | feature_value | 7 | 7 | 0 | match |
| 194 | integer_value | :warn | quota | enabled=true included=nil kind=:feature limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=7 | enabled=true included=nil kind=:feature limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=7 | 0 | match |
| 195 | integer_value | :warn | remaining | :unlimited | :unlimited | 0 | match |
| 196 | integer_value | :warn | reserve | :ok | :ok | 1 | match |
| 197 | integer_value | :warn | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 198 | integer_value | :warn | track | :ok | :ok | 3 | match |
| 199 | integer_value | :deny | check | :ok | :ok | 0 | match |
| 200 | integer_value | :deny | allowed? | true | true | 0 | match |
| 201 | integer_value | :deny | entitled? | true | true | 0 | match |
| 202 | integer_value | :deny | feature_value | 7 | 7 | 0 | match |
| 203 | integer_value | :deny | quota | enabled=true included=nil kind=:feature limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=7 | enabled=true included=nil kind=:feature limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=7 | 0 | match |
| 204 | integer_value | :deny | remaining | :unlimited | :unlimited | 0 | match |
| 205 | integer_value | :deny | reserve | :ok | :ok | 1 | match |
| 206 | integer_value | :deny | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 207 | integer_value | :deny | track | :ok | :ok | 3 | match |
| 208 | integer_value | :raise | check | :ok | :ok | 0 | match |
| 209 | integer_value | :raise | allowed? | true | true | 0 | match |
| 210 | integer_value | :raise | entitled? | true | true | 0 | match |
| 211 | integer_value | :raise | feature_value | 7 | 7 | 0 | match |
| 212 | integer_value | :raise | quota | enabled=true included=nil kind=:feature limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=7 | enabled=true included=nil kind=:feature limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=7 | 0 | match |
| 213 | integer_value | :raise | remaining | :unlimited | :unlimited | 0 | match |
| 214 | integer_value | :raise | reserve | :ok | :ok | 1 | match |
| 215 | integer_value | :raise | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 216 | integer_value | :raise | track | :ok | :ok | 3 | match |
| 217 | undeclared_anywhere | :allow | check | :ok | :ok | 0 | match |
| 218 | undeclared_anywhere | :allow | allowed? | true | true | 0 | match |
| 219 | undeclared_anywhere | :allow | entitled? | true | true | 0 | match |
| 220 | undeclared_anywhere | :allow | feature_value | :no_value | :no_value | 0 | match |
| 221 | undeclared_anywhere | :allow | quota | enabled=true included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 222 | undeclared_anywhere | :allow | remaining | :unlimited | :unlimited | 0 | match |
| 223 | undeclared_anywhere | :allow | reserve | :ok | :ok | 1 | match |
| 224 | undeclared_anywhere | :allow | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 225 | undeclared_anywhere | :allow | track | :ok | :ok | 3 | match |
| 226 | undeclared_anywhere | :warn | check | :ok | :ok | 0 | match |
| 227 | undeclared_anywhere | :warn | allowed? | true | true | 0 | match |
| 228 | undeclared_anywhere | :warn | entitled? | true | true | 0 | match |
| 229 | undeclared_anywhere | :warn | feature_value | :no_value | :no_value | 0 | match |
| 230 | undeclared_anywhere | :warn | quota | enabled=true included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 231 | undeclared_anywhere | :warn | remaining | :unlimited | :unlimited | 0 | match |
| 232 | undeclared_anywhere | :warn | reserve | :ok | :ok | 1 | match |
| 233 | undeclared_anywhere | :warn | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 234 | undeclared_anywhere | :warn | track | :ok | :ok | 3 | match |
| 235 | undeclared_anywhere | :deny | check | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 236 | undeclared_anywhere | :deny | allowed? | false | false | 0 | match |
| 237 | undeclared_anywhere | :deny | entitled? | false | false | 0 | match |
| 238 | undeclared_anywhere | :deny | feature_value | :no_value | :no_value | 0 | match |
| 239 | undeclared_anywhere | :deny | quota | enabled=false included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=false included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 240 | undeclared_anywhere | :deny | remaining | 0 | 0 | 0 | match |
| 241 | undeclared_anywhere | :deny | reserve | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 242 | undeclared_anywhere | :deny | with_quota | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 243 | undeclared_anywhere | :deny | track | :ok | :ok | 3 | match |
| 244 | undeclared_anywhere | :raise | check | :raises | {:raised, :unknown_feature} | 0 | match |
| 245 | undeclared_anywhere | :raise | allowed? | :raises | {:raised, :unknown_feature} | 0 | match |
| 246 | undeclared_anywhere | :raise | entitled? | :raises | {:raised, :unknown_feature} | 0 | match |
| 247 | undeclared_anywhere | :raise | feature_value | :raises | {:raised, :unknown_feature} | 0 | match |
| 248 | undeclared_anywhere | :raise | quota | :raises | {:raised, :unknown_feature} | 0 | match |
| 249 | undeclared_anywhere | :raise | remaining | :raises | {:raised, :unknown_feature} | 0 | match |
| 250 | undeclared_anywhere | :raise | reserve | :raises | {:raised, :unknown_feature} | 0 | match |
| 251 | undeclared_anywhere | :raise | with_quota | :raises | {:raised, :unknown_feature} | 0 | match |
| 252 | undeclared_anywhere | :raise | track | :ok | :ok | 3 | match |
| 253 | declared_on_another_plan | :allow | check | :ok | :ok | 0 | match |
| 254 | declared_on_another_plan | :allow | allowed? | true | true | 0 | match |
| 255 | declared_on_another_plan | :allow | entitled? | true | true | 0 | match |
| 256 | declared_on_another_plan | :allow | feature_value | :no_value | :no_value | 0 | match |
| 257 | declared_on_another_plan | :allow | quota | enabled=true included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 258 | declared_on_another_plan | :allow | remaining | :unlimited | :unlimited | 0 | match |
| 259 | declared_on_another_plan | :allow | reserve | :ok | :ok | 1 | match |
| 260 | declared_on_another_plan | :allow | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 261 | declared_on_another_plan | :allow | track | :ok | :ok | 3 | match |
| 262 | declared_on_another_plan | :warn | check | :ok | :ok | 0 | match |
| 263 | declared_on_another_plan | :warn | allowed? | true | true | 0 | match |
| 264 | declared_on_another_plan | :warn | entitled? | true | true | 0 | match |
| 265 | declared_on_another_plan | :warn | feature_value | :no_value | :no_value | 0 | match |
| 266 | declared_on_another_plan | :warn | quota | enabled=true included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=true included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 267 | declared_on_another_plan | :warn | remaining | :unlimited | :unlimited | 0 | match |
| 268 | declared_on_another_plan | :warn | reserve | :ok | :ok | 1 | match |
| 269 | declared_on_another_plan | :warn | with_quota | {:ok, :ran} | {:ok, :ran} | 1 | match |
| 270 | declared_on_another_plan | :warn | track | :ok | :ok | 3 | match |
| 271 | declared_on_another_plan | :deny | check | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 272 | declared_on_another_plan | :deny | allowed? | false | false | 0 | match |
| 273 | declared_on_another_plan | :deny | entitled? | false | false | 0 | match |
| 274 | declared_on_another_plan | :deny | feature_value | :no_value | :no_value | 0 | match |
| 275 | declared_on_another_plan | :deny | quota | enabled=false included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | enabled=false included=nil kind=:undeclared limit=nil overage=0 percent=nil remaining=:unlimited unit_price=nil used=0 value=nil | 0 | match |
| 276 | declared_on_another_plan | :deny | remaining | 0 | 0 | 0 | match |
| 277 | declared_on_another_plan | :deny | reserve | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 278 | declared_on_another_plan | :deny | with_quota | {:error, :not_entitled} | {:error, :not_entitled} | 0 | match |
| 279 | declared_on_another_plan | :deny | track | :ok | :ok | 3 | match |
| 280 | declared_on_another_plan | :raise | check | :raises | {:raised, :not_in_plan} | 0 | match |
| 281 | declared_on_another_plan | :raise | allowed? | :raises | {:raised, :not_in_plan} | 0 | match |
| 282 | declared_on_another_plan | :raise | entitled? | :raises | {:raised, :not_in_plan} | 0 | match |
| 283 | declared_on_another_plan | :raise | feature_value | :raises | {:raised, :not_in_plan} | 0 | match |
| 284 | declared_on_another_plan | :raise | quota | :raises | {:raised, :not_in_plan} | 0 | match |
| 285 | declared_on_another_plan | :raise | remaining | :raises | {:raised, :not_in_plan} | 0 | match |
| 286 | declared_on_another_plan | :raise | reserve | :raises | {:raised, :not_in_plan} | 0 | match |
| 287 | declared_on_another_plan | :raise | with_quota | :raises | {:raised, :not_in_plan} | 0 | match |
| 288 | declared_on_another_plan | :raise | track | :ok | :ok | 3 | match |

cases: 288, mismatches: 0 (the run's own final line, log `tmp/v1/02b/logs/22-matrix.log`).
