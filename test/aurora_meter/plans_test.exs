defmodule AuroraMeter.PlansTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AuroraMeter.Plan
  alias AuroraMeter.Plans

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
