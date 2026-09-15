defmodule AuroraMeter.PlansTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AuroraMeter.Plan
  alias AuroraMeter.Plans

  doctest AuroraMeter.Plans

  test "all/0 returns every defined plan" do
    plans = Plans.all()

    assert plans |> Map.keys() |> Enum.sort() ==
             [:allowance, :allowance_flat, :free, :payg, :pro, :scale]

    assert %Plan{id: :free, price: 0} = plans[:free]
  end

  test "get/1 returns a plan by id, or nil" do
    assert %Plan{id: :pro, price: 2_000} = Plans.get(:pro)
    assert Plans.get(:nope) == nil
  end

  test "feature_config/2 returns the config tuple for each feature kind" do
    assert Plans.feature_config(:free, :ai_generations) == {:limit, 50, :hard}
    assert Plans.feature_config(:scale, :ai_generations) == {:metered, 1_000, 2}
    assert Plans.feature_config(:payg, :requests) == {:counter}
    assert Plans.feature_config(:pro, :api_access) == {:feature, true}
    assert Plans.feature_config(:pro, :seats) == {:feature, 5}
    assert Plans.feature_config(:free, :unknown) == nil
    assert Plans.feature_config(:missing_plan, :x) == nil
  end

  test "a duplicate feature raises at compile time" do
    assert catch_error(
             Code.eval_string("""
             defmodule AuroraMeterDupPlan do
               use AuroraMeter.Plans
               plan :x do
                 limit :a, 1, :hard
                 limit :a, 2, :hard
               end
             end
             """)
           )
  end

  test "feature_value/3 returns booleans and integers, else the default" do
    assert Plans.feature_value(:free, :seats) == 1
    assert Plans.feature_value(:scale, :seats) == 25
    assert Plans.feature_value(:free, :api_access) == false
    assert Plans.feature_value(:free, :ai_generations) == nil
    assert Plans.feature_value(:free, :ai_generations, :none) == :none
    assert Plans.feature_value(:free, :undeclared, 0) == 0
    assert Plans.feature_value(:missing_plan, :seats, 0) == 0
  end

  test "an integer feature must be a non-negative integer" do
    assert catch_error(
             Code.eval_string("""
             defmodule AuroraMeterNegativeFeature do
               use AuroraMeter.Plans
               plan :x do
                 feature :seats, -1
               end
             end
             """)
           )

    assert catch_error(
             Code.eval_string("""
             defmodule AuroraMeterStringFeature do
               use AuroraMeter.Plans
               plan :x do
                 feature :seats, "five"
               end
             end
             """)
           )
  end

  test "counter/1 declares a feature with no denominator at all" do
    assert Plans.feature_config(:payg, :requests) == {:counter}

    # A counter carries no value: it is measured, not declared.
    assert Plans.feature_value(:payg, :requests) == nil
    assert Plans.feature_value(:payg, :requests, :none) == :none
  end

  test "a counter may be declared in any plan and does not collide with other kinds" do
    {{:module, module, _, _}, _} =
      Code.eval_string("""
      defmodule AuroraMeterCounterPlan#{System.unique_integer([:positive])} do
        use AuroraMeter.Plans
        plan :x do
          counter :requests
          limit :seats_used, 3, :hard
          metered :tokens, included: 10, unit_price: 1
          feature :api_access, true
        end
      end
      """)

    plan = module.__aurora_plans__()[:x]

    assert plan.features == %{
             requests: {:counter},
             seats_used: {:limit, 3, :hard},
             tokens: {:metered, 10, 1},
             api_access: {:feature, true}
           }
  end

  test "a counter declared twice still raises as a duplicate" do
    assert catch_error(
             Code.eval_string("""
             defmodule AuroraMeterDupCounter do
               use AuroraMeter.Plans
               plan :x do
                 counter :requests
                 counter :requests
               end
             end
             """)
           )
  end

  test "a negative limit raises at compile time" do
    assert catch_error(
             Code.eval_string("""
             defmodule AuroraMeterBadLimit do
               use AuroraMeter.Plans
               plan :x do
                 limit :a, -1, :hard
               end
             end
             """)
           )
  end

  # -- recurring credits (build unit 06d) --------------------------------------

  test "I18 recurring_credits stores name, amount, category, rollover and expires on the plan" do
    assert Plans.get(:allowance).recurring_credits == [
             %{
               name: :monthly,
               amount: 5_000_000,
               category: :promotional,
               rollover: 1_000_000,
               expires: :period_end
             }
           ]

    # Defaults: promotional, no rollover, expires with the period.
    assert Plans.get(:allowance_flat).recurring_credits == [
             %{
               name: :monthly,
               amount: 5_000_000,
               category: :promotional,
               rollover: 0,
               expires: :period_end
             }
           ]
  end

  test "I18 a plan without recurring_credits has an empty list" do
    for id <- [:free, :pro, :scale, :payg] do
      assert Plans.get(id).recurring_credits == [], "plan #{id}"
    end
  end

  test "I18 declaration order is preserved and features are untouched" do
    plan =
      build_plan("""
        counter :requests
        recurring_credits :first, amount: 1
        feature :api_access, true
        recurring_credits :second, amount: 2, category: :paid, expires: :never
      """)

    assert Enum.map(plan.recurring_credits, & &1.name) == [:first, :second]
    assert plan.features == %{requests: {:counter}, api_access: {:feature, true}}
  end

  test "I18 a duplicate entitlement name in one plan raises at compile time" do
    assert compile_error("""
             recurring_credits :monthly, amount: 1
             recurring_credits :monthly, amount: 2
           """) =~ "duplicate recurring_credits name(s): [:monthly]"
  end

  test "I18 a float amount raises at compile time" do
    assert compile_error("recurring_credits :monthly, amount: 5_000_000.0") =~
             ":amount must be a positive integer"

    assert compile_error("recurring_credits :monthly, amount: 0") =~
             ":amount must be a positive integer"

    assert compile_error("recurring_credits :monthly, rollover: 1") =~ "needs an :amount"
  end

  test "I18 rollover greater than zero with expires: :never raises at compile time" do
    assert compile_error("recurring_credits :monthly, amount: 10, rollover: 1, expires: :never") =~
             "A rollover is what the previous period's lot did not spend"

    # And with any other non-boundary expiry, for the same reason: the carried
    # value would still be spendable on the old lot.
    assert compile_error(
             "recurring_credits :monthly, amount: 10, rollover: 1, expires: {:seconds, 60}"
           ) =~ "A rollover is what the previous period's lot did not spend"
  end

  test "I18 an expiring allowance must be promotional, because only promotional grants expire" do
    assert compile_error("recurring_credits :monthly, amount: 10, category: :paid") =~
             "Only promotional grants expire"

    # The combination the ledger does accept.
    assert build_plan("recurring_credits :monthly, amount: 10, category: :paid, expires: :never").recurring_credits ==
             [%{name: :monthly, amount: 10, category: :paid, rollover: 0, expires: :never}]
  end

  test "I18 an unknown option, category or expiry raises at compile time" do
    assert compile_error("recurring_credits :monthly, amount: 10, roll_over: 1") =~
             "unknown option(s) [:roll_over]"

    assert compile_error("recurring_credits :monthly, amount: 10, category: :bonus") =~
             ":category must be one of"

    assert compile_error("recurring_credits :monthly, amount: 10, expires: :tomorrow") =~
             ":expires must be :period_end, :never or {:seconds, n}"

    assert compile_error("recurring_credits :monthly, amount: 10, rollover: -1") =~
             ":rollover must be a non-negative integer"
  end

  # X272's rule, applied where the string is invented: both halves of a
  # recurrence key are read back by splitting on ":", so neither may contain
  # one. A test that only checked the entitlement name would miss the plan id,
  # which is the half a host is more likely to spell oddly.
  test "I18 a name or plan id that cannot be read back out of a recurrence key raises" do
    assert compile_error("recurring_credits :\"monthly:extra\", amount: 10") =~
             "must be lower snake case"

    assert compile_error("recurring_credits :Monthly, amount: 10") =~ "must be lower snake case"

    assert plan_error(:"pro:legacy", "recurring_credits :monthly, amount: 10") =~
             "becomes part of a recurrence key"
  end

  test "I18 a never-expiring promotional allowance compiles and warns" do
    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        plan = build_plan("recurring_credits :monthly, amount: 10, expires: :never")
        send(self(), {:plan, plan})
      end)

    assert_received {:plan, plan}
    assert [%{expires: :never, category: :promotional}] = plan.recurring_credits
    assert warning =~ "never expires"
  end

  defp build_plan(body, id \\ :x) do
    {{:module, module, _, _}, _} =
      Code.eval_string("""
      defmodule AuroraMeterRecurring#{System.unique_integer([:positive])} do
        use AuroraMeter.Plans
        plan #{inspect(id)} do
      #{body}
        end
      end
      """)

    module.__aurora_plans__()[id]
  end

  defp compile_error(body, id \\ :x) do
    Exception.message(catch_error(build_plan(body, id)))
  end

  defp plan_error(id, body), do: compile_error(body, id)
end
