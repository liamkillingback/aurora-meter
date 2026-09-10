defmodule AuroraMeter.PlansTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AuroraMeter.Plan
  alias AuroraMeter.Plans

  doctest AuroraMeter.Plans

  test "all/0 returns every defined plan" do
    plans = Plans.all()
    assert plans |> Map.keys() |> Enum.sort() == [:free, :pro, :scale]
    assert %Plan{id: :free, price: 0} = plans[:free]
  end

  test "get/1 returns a plan by id, or nil" do
    assert %Plan{id: :pro, price: 2_000} = Plans.get(:pro)
    assert Plans.get(:nope) == nil
  end

  test "feature_config/2 returns the config tuple for each feature kind" do
    assert Plans.feature_config(:free, :ai_generations) == {:limit, 50, :hard}
    assert Plans.feature_config(:scale, :ai_generations) == {:metered, 1_000, 2}
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
end
