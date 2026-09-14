defmodule AuroraMeter.Test.PolicyPlans do
  @moduledoc """
  Plans for the undeclared-feature matrix (build unit 02b).

  One plan declaring every feature kind exactly once, one plan declaring a
  feature the first does not, and a bare default plan. The point of the second
  plan is the case `:undeclared_feature_policy` exists for: a tenant on
  `:policy` asking about `:elsewhere` is undeclared *for that tenant* even
  though another plan declares it, which is what separates `reason:
  :not_in_plan` from `reason: :unknown_feature`.

  `:nowhere` is deliberately declared by nothing at all, here or in
  AuroraMeter.TestPlans.

  These ship in no archive: `elixirc_paths(:test)` compiles `test/support`.
  """

  use AuroraMeter.Plans

  # The configured :default_plan, so a tenant without a subscription still
  # resolves to a plan while this module is installed.
  plan :free do
    price 0
  end

  plan :policy do
    price 1_000
    limit :policy_hard, 50, :hard
    metered :policy_metered, included: 100, unit_price: 2
    counter :policy_counter
    feature :policy_boolean_true, true
    feature :policy_boolean_false, false
    feature :policy_integer, 7
  end

  plan :policy_other do
    price 2_000
    feature :elsewhere, true
  end
end

defmodule AuroraMeter.Test.FloatPricePlans do
  @moduledoc """
  A plans module with a float `unit_price`, for the boot warning (build unit
  02b). `aurora_api` ships floats today, so this is a warning and never a
  refusal to boot.
  """

  use AuroraMeter.Plans

  plan :free do
    price 0
    metered :float_priced, included: 10, unit_price: 0.05
  end

  plan :pro do
    price 100
    metered :float_priced, included: 100, unit_price: 0.05
  end
end

defmodule AuroraMeter.Test.NoDefaultPlanPlans do
  @moduledoc """
  A plans module that declares no `:free` plan, for the `:default_plan`
  existence check (build unit 02b).
  """

  use AuroraMeter.Plans

  plan :something_else do
    price 0
  end
end
