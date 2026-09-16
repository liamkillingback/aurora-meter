defmodule AuroraMeter.TestPlans do
  @moduledoc false
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :ai_generations, 50, :hard
    feature :api_access, false
    feature :seats, 1
  end

  plan :pro do
    price 2_000
    limit :ai_generations, 1_000, :hard
    feature :api_access, true
    feature :seats, 5
  end

  plan :scale do
    price 2_000
    metered :ai_generations, included: 1_000, unit_price: 2
    feature :api_access, true
    feature :seats, 25
  end

  # Pay-as-you-go: requests are measured for the dashboard, the money lives in
  # the credit ledger, so `:requests` is a counter and not a metered feature.
  plan :payg do
    price 0
    counter :requests
    feature :api_access, true
    feature :seats, 25
  end

  # Build unit 06d. Two plans that declare a recurring allowance, one with a
  # rollover cap and one without, plus the four above that declare none, so a
  # test can assert both that an allowance is granted and that a plan without
  # one grants nothing.
  plan :allowance do
    price 4_900
    counter :requests
    feature :api_access, true
    recurring_credits :monthly, amount: 5_000_000, rollover: 1_000_000, expires: :period_end
  end

  plan :allowance_flat do
    price 4_900
    counter :requests
    feature :api_access, true
    recurring_credits :monthly, amount: 5_000_000
  end

  # Build unit 07a. A plan with two versions, the second future dated far past
  # any date the suite freezes its clock to, so `:versioned` answers version "1"
  # in an ordinary test and version "2" only inside a `with_clock/2` block that
  # travels past the boundary. Every commercial field differs between the two,
  # because a test that only moves the price cannot tell "the version resolved"
  # from "the price resolved".
  plan :versioned do
    price 2_000
    limit :ai_generations, 1_000, :hard
    feature :api_access, true
    feature :seats, 5
    recurring_credits :monthly, amount: 5_000_000, rollover: 1_000_000, expires: :period_end
  end

  plan :versioned, version: "2", effective_at: ~U[2030-01-01 00:00:00Z] do
    price 3_000
    limit :ai_generations, 2_000, :hard
    feature :api_access, true
    feature :seats, 25
    recurring_credits :monthly, amount: 9_000_000, rollover: 3_000_000, expires: :period_end
  end
end

# `AuroraMeter.TestPlans` with `:versioned` version 2 already effective, and
# nothing else changed. Swapped in with `AuroraMeter.Test.Config.with_config/2`
# to prove that deploying a new version does not move a tenant already on
# version 1 (build unit 07a, G07 bullet 1). The instant is in the past rather
# than `nil`, because a second version with no `effective_at` would be a second
# base version and the compiler refuses that.
defmodule AuroraMeter.Test.VersionTwoLivePlans do
  @moduledoc false
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :ai_generations, 50, :hard
    feature :api_access, false
    feature :seats, 1
  end

  plan :versioned do
    price 2_000
    limit :ai_generations, 1_000, :hard
    feature :api_access, true
    feature :seats, 5
    recurring_credits :monthly, amount: 5_000_000, rollover: 1_000_000, expires: :period_end
  end

  plan :versioned, version: "2", effective_at: ~U[2020-01-01 00:00:00Z] do
    price 3_000
    limit :ai_generations, 2_000, :hard
    feature :api_access, true
    feature :seats, 25
    recurring_credits :monthly, amount: 9_000_000, rollover: 3_000_000, expires: :period_end
  end
end

# The same module with version 1's block **deleted**, which is the shape
# acceptance criterion 9 is about: a tenant pinned to `:versioned` version 1
# must keep version 1's limits, resolved from the stored snapshot, when the
# only definition left in code is version 2. Version 2 loses its
# `effective_at`, because it is now the plan's only version and every plan id
# needs a base version.
defmodule AuroraMeter.Test.VersionOneDeletedPlans do
  @moduledoc false
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :ai_generations, 50, :hard
    feature :api_access, false
    feature :seats, 1
  end

  plan :versioned, version: "2" do
    price 3_000
    limit :ai_generations, 2_000, :hard
    feature :api_access, true
    feature :seats, 25
    recurring_credits :monthly, amount: 9_000_000, rollover: 3_000_000, expires: :period_end
  end
end

# A plans module whose base version is **not** `"1"`. `schema-migration-map.md`
# S6 quotes the legacy assignment as writing the literal `'1'`, and for every
# plans module that never names a version that is the same string as the base
# version, which is why a suite built only on `AuroraMeter.TestPlans` cannot
# tell the two rules apart (finding X287, found by the negative control).
defmodule AuroraMeter.Test.RenamedBaseVersionPlans do
  @moduledoc false
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :ai_generations, 50, :hard
    feature :api_access, false
    feature :seats, 1
  end

  plan :renamed, version: "2024-01" do
    price 1_500
    limit :ai_generations, 300, :hard
    feature :api_access, true
    feature :seats, 3
  end
end

# `:versioned` version 1 with its price edited in place, which is the thing
# plan versions exist to refuse. Registering it against a database that already
# holds version 1's snapshot is `AuroraMeter.PlanVersionConflictError`.
defmodule AuroraMeter.Test.EditedVersionPlans do
  @moduledoc false
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :ai_generations, 50, :hard
    feature :api_access, false
    feature :seats, 1
  end

  plan :versioned do
    price 9_900
    limit :ai_generations, 1_000, :hard
    feature :api_access, true
    feature :seats, 5
    recurring_credits :monthly, amount: 5_000_000, rollover: 1_000_000, expires: :period_end
  end
end

# AuroraMeter.TestPlans after a plan edit: the same plan id and the same
# entitlement name, with a bigger allowance and a bigger rollover cap.
#
# Swapped in with AuroraMeter.Test.Config.with_config/2 to drive build unit
# 06d's policy-snapshot criterion. Both numbers change, because only one of them
# can discriminate: a retry cannot re-grant whatever amount it reads (the
# recurrence row and the grant commit together), while the CAP decides a number
# every time a period carries value out of itself.
defmodule AuroraMeter.Test.EditedPlans do
  @moduledoc false
  use AuroraMeter.Plans

  plan :allowance do
    price 4_900
    counter :requests
    feature :api_access, true
    recurring_credits :monthly, amount: 9_000_000, rollover: 3_000_000, expires: :period_end
  end
end
