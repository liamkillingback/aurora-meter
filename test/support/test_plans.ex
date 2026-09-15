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
