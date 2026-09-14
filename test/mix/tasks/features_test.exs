defmodule Mix.Tasks.AuroraMeter.FeaturesTest do
  @moduledoc false
  # Build unit 02b. The scanner an operator runs before flipping
  # :undeclared_feature_policy to :deny.
  #
  # async: false: the two tests that run the task itself override :plans.
  use ExUnit.Case, async: false

  import AuroraMeter.Test.Config, only: [with_config: 2]
  import ExUnit.CaptureIO

  alias Mix.Tasks.AuroraMeter.Features

  @plans AuroraMeter.Test.PolicyPlans
  @no_features AuroraMeter.Test.NoDefaultPlanPlans

  test "lists declared features per plan" do
    output = render(plans: @plans, core_env: [], pro_env: [])

    assert output =~ "Aurora Meter features, from AuroraMeter.Test.PolicyPlans"
    assert output =~ "policy (price 1000)"
    assert output =~ "policy_hard: hard limit, 50"
    assert output =~ "policy_metered: metered, 100 included, 2"
    assert output =~ "policy_counter: counter"
    assert output =~ "policy_boolean_true: feature, granted"
    assert output =~ "policy_boolean_false: feature, denied"
    assert output =~ "policy_integer: feature value, 7"
    assert output =~ "policy_other (price 2000)"
  end

  test "reports a durable_features entry that no plan declares" do
    env = [durable_features: [:policy_hard, :not_a_feature]]
    report = Features.report(plans: @plans, core_env: env, pro_env: [])

    assert report.undeclared == [
             %{feature: :not_a_feature, source: "config :aurora_meter, :durable_features"}
           ]

    output = Features.render(report)
    assert output =~ "config :aurora_meter, :durable_features: :not_a_feature, :policy_hard"
    assert output =~ ":not_a_feature is referenced by config :aurora_meter, :durable_features"
    assert output =~ "declared by no plan"
    refute Features.clean?(report)
  end

  test "an absent configuration key is skipped, not reported as empty" do
    report = Features.report(plans: @plans, core_env: [], pro_env: [])

    assert report.references == []
    assert Features.render(report) =~ "2. Features referenced by configuration\n  (none)"
  end

  test "reports a plan gap with the plans that would deny it" do
    report = Features.report(plans: @plans, core_env: [], pro_env: [])

    assert %{feature: :policy_hard, declared_in: [:policy], would_deny: deny} =
             Enum.find(report.gaps, &(&1.feature == :policy_hard))

    assert deny == [:free, :policy_other]

    output = Features.render(report)
    assert output =~ ":policy_hard: declared on :policy; would be denied on :free, :policy_other"
  end

  test "reads aurora_meter_pro's stripe_meters when that application environment is present" do
    pro_env = [stripe_meters: %{policy_metered: "meter_a", never_declared: "meter_b"}]
    report = Features.report(plans: @plans, core_env: [], pro_env: pro_env)

    assert %{feature: :never_declared, source: "config :aurora_meter_pro, :stripe_meters"} in report.undeclared

    assert Features.render(report) =~
             "config :aurora_meter_pro, :stripe_meters: :never_declared, :policy_metered"
  end

  test "a fully declared configuration with no gaps is clean" do
    report = Features.report(plans: @no_features, core_env: [], pro_env: [])

    assert report.undeclared == []
    assert report.gaps == []
    assert Features.clean?(report)
  end

  describe "the task itself" do
    test "--strict exits 1 when a plan gap exists" do
      with_config([{:aurora_meter, :plans, @plans}], fn ->
        assert_raise Mix.Error, ~r/--strict/, fn ->
          capture_io(fn -> Features.run(["--strict"]) end)
        end
      end)
    end

    test "--strict exits 1 when an undeclared reference exists" do
      with_config(
        [
          {:aurora_meter, :plans, @no_features},
          {:aurora_meter, :durable_features, [:not_a_feature]}
        ],
        fn ->
          assert_raise Mix.Error, ~r/--strict/, fn ->
            capture_io(fn -> Features.run(["--strict"]) end)
          end
        end
      )
    end

    test "--strict exits 0 on a fully declared configuration" do
      with_config([{:aurora_meter, :plans, @no_features}], fn ->
        output = capture_io(fn -> Features.run(["--strict"]) end)

        assert output =~ "3. Undeclared references\n  (none)"
        assert output =~ "4. Plan gaps\n  (none)"
      end)
    end

    test "--plans overrides the configured module" do
      output = capture_io(fn -> Features.run(["--plans", "AuroraMeter.Test.PolicyPlans"]) end)

      assert output =~ "from AuroraMeter.Test.PolicyPlans"
    end
  end

  defp render(opts), do: opts |> Features.report() |> Features.render()
end
