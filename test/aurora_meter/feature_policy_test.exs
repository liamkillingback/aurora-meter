defmodule AuroraMeter.FeaturePolicyTest do
  @moduledoc false
  # Build unit 02b, gate G02 bullet 1: every feature kind crossed with every
  # value of :undeclared_feature_policy at every public entry point.
  #
  # The expectations below are a table, written out, not computed from the code
  # under test. The declared half is keyed by kind alone and the undeclared half
  # by policy alone, which is B04 made structural: if policy could change a
  # declared feature's answer, there would be nowhere in this table to write it.
  #
  # async: false - every test mutates the node's application environment
  # (:plans and :undeclared_feature_policy) through AuroraMeter.Test.Config.
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test.Config, only: [with_config: 2]
  import ExUnit.CaptureLog

  alias AuroraMeter.Config.Schema, as: ConfigSchema
  alias AuroraMeter.UndeclaredFeatureError

  @policies [:allow, :warn, :deny, :raise]

  @entry_points [
    :check,
    :allowed?,
    :entitled?,
    :feature_value,
    :quota,
    :remaining,
    :reserve,
    :with_quota,
    :track
  ]

  @quota_keys [
    :feature,
    :kind,
    :enabled,
    :value,
    :used,
    :limit,
    :included,
    :unit_price,
    :remaining,
    :overage,
    :percent,
    :period
  ]

  # Six declared kinds. No entry here mentions a policy, because none of them
  # depends on one.
  @declared %{
    hard: %{
      feature: :policy_hard,
      check: :ok,
      allowed?: true,
      entitled?: true,
      feature_value: :no_value,
      quota: %{
        kind: :hard,
        enabled: true,
        value: nil,
        used: 0,
        limit: 50,
        included: 50,
        unit_price: nil,
        remaining: 50,
        overage: 0,
        percent: 0
      },
      remaining: 50,
      reserve: :ok,
      reserved: 1,
      with_quota: {:ok, :ran},
      ran?: true,
      track: :ok
    },
    metered: %{
      feature: :policy_metered,
      check: :ok,
      allowed?: true,
      entitled?: true,
      feature_value: :no_value,
      quota: %{
        kind: :metered,
        enabled: true,
        value: nil,
        used: 0,
        limit: nil,
        included: 100,
        unit_price: 2,
        remaining: :unlimited,
        overage: 0,
        percent: 0
      },
      remaining: :unlimited,
      reserve: :ok,
      reserved: 1,
      with_quota: {:ok, :ran},
      ran?: true,
      track: :ok
    },
    counter: %{
      feature: :policy_counter,
      check: :ok,
      allowed?: true,
      entitled?: true,
      feature_value: :no_value,
      quota: %{
        kind: :counter,
        enabled: true,
        value: nil,
        used: 0,
        limit: nil,
        included: nil,
        unit_price: nil,
        remaining: :unlimited,
        overage: 0,
        percent: nil
      },
      remaining: :unlimited,
      reserve: :ok,
      reserved: 1,
      with_quota: {:ok, :ran},
      ran?: true,
      track: :ok
    },
    boolean_true: %{
      feature: :policy_boolean_true,
      check: :ok,
      allowed?: true,
      entitled?: true,
      feature_value: true,
      quota: %{
        kind: :boolean,
        enabled: true,
        value: nil,
        used: 0,
        limit: nil,
        included: nil,
        unit_price: nil,
        remaining: :unlimited,
        overage: 0,
        percent: nil
      },
      remaining: :unlimited,
      reserve: :ok,
      reserved: 1,
      with_quota: {:ok, :ran},
      ran?: true,
      track: :ok
    },
    boolean_false: %{
      feature: :policy_boolean_false,
      check: {:error, :not_entitled},
      allowed?: false,
      entitled?: false,
      feature_value: false,
      quota: %{
        kind: :boolean,
        enabled: false,
        value: nil,
        used: 0,
        limit: nil,
        included: nil,
        unit_price: nil,
        remaining: :unlimited,
        overage: 0,
        percent: nil
      },
      remaining: :unlimited,
      reserve: {:error, :not_entitled},
      reserved: 0,
      with_quota: {:error, :not_entitled},
      ran?: false,
      track: :ok
    },
    integer_value: %{
      feature: :policy_integer,
      check: :ok,
      allowed?: true,
      entitled?: true,
      feature_value: 7,
      quota: %{
        kind: :feature,
        enabled: true,
        value: 7,
        used: 0,
        limit: nil,
        included: nil,
        unit_price: nil,
        remaining: :unlimited,
        overage: 0,
        percent: nil
      },
      remaining: :unlimited,
      reserve: :ok,
      reserved: 1,
      with_quota: {:ok, :ran},
      ran?: true,
      track: :ok
    }
  }

  @permissive %{
    check: :ok,
    allowed?: true,
    entitled?: true,
    feature_value: :no_value,
    quota: %{
      kind: :undeclared,
      enabled: true,
      value: nil,
      used: 0,
      limit: nil,
      included: nil,
      unit_price: nil,
      remaining: :unlimited,
      overage: 0,
      percent: nil
    },
    remaining: :unlimited,
    reserve: :ok,
    reserved: 1,
    with_quota: {:ok, :ran},
    ran?: true,
    track: :ok
  }

  # The two undeclared kinds share one table, keyed by policy alone: whether a
  # feature is declared on some *other* plan changes the reason and the message,
  # never the outcome.
  @undeclared %{
    allow: @permissive,
    warn: @permissive,
    deny: %{
      check: {:error, :not_entitled},
      allowed?: false,
      entitled?: false,
      feature_value: :no_value,
      quota: %{
        kind: :undeclared,
        enabled: false,
        value: nil,
        used: 0,
        limit: nil,
        included: nil,
        unit_price: nil,
        remaining: :unlimited,
        overage: 0,
        percent: nil
      },
      remaining: 0,
      reserve: {:error, :not_entitled},
      reserved: 0,
      with_quota: {:error, :not_entitled},
      ran?: false,
      track: :ok
    },
    raise: %{
      check: :raises,
      allowed?: :raises,
      entitled?: :raises,
      feature_value: :raises,
      quota: :raises,
      remaining: :raises,
      reserve: :raises,
      reserved: 0,
      with_quota: :raises,
      ran?: false,
      track: :ok
    }
  }

  # :nowhere is declared by no plan at all; :elsewhere is declared by :policy_other
  # and not by :policy, which is the tenant's plan throughout.
  @undeclared_kinds %{undeclared_anywhere: :nowhere, declared_on_another_plan: :elsewhere}

  @doc false
  def handle_event(event, measurements, metadata, %{parent: parent, tenant: tenant}) do
    if metadata.tenant_key == tenant,
      do: send(parent, {:telemetry, event, measurements, metadata})

    :ok
  end

  for {kind, expected} <- @declared, policy <- @policies, entry_point <- @entry_points do
    @case_feature expected.feature
    @case_expected expected
    @case_policy policy
    @case_entry_point entry_point

    test "#{kind}/#{entry_point} under #{inspect(policy)}" do
      assert_case(@case_policy, @case_feature, @case_entry_point, @case_expected)
    end
  end

  for {kind, feature} <- @undeclared_kinds, policy <- @policies, entry_point <- @entry_points do
    @case_feature feature
    @case_expected Map.fetch!(@undeclared, policy)
    @case_policy policy
    @case_entry_point entry_point

    test "#{kind}/#{entry_point} under #{inspect(policy)}" do
      assert_case(@case_policy, @case_feature, @case_entry_point, @case_expected)
    end
  end

  test "the generated matrix covers every kind, policy and entry point" do
    kinds = Map.keys(@declared) ++ Map.keys(@undeclared_kinds)

    assert length(kinds) == 8
    assert length(@policies) == 4
    assert length(@entry_points) == 9
    assert length(kinds) * length(@policies) * length(@entry_points) == 288
  end

  test "B04 policy does not change the result for a declared feature" do
    by_policy =
      Map.new(@policies, fn policy ->
        {policy,
         in_policy(policy, fn ->
           for {kind, expected} <- Enum.sort(@declared), entry_point <- @entry_points do
             tenant = subscribed()
             result = call(entry_point, tenant, expected.feature)
             flush_ran()
             {kind, entry_point, result}
           end
         end)}
      end)

    reference = by_policy[:allow]

    for policy <- [:warn, :deny, :raise] do
      assert by_policy[policy] == reference,
             "a declared feature answered differently under #{inspect(policy)}"
    end
  end

  test "B05 every entry point keeps its documented return shape under every policy" do
    for policy <- @policies do
      in_policy(policy, fn ->
        tenant = subscribed()
        assert_shapes(tenant, :nowhere, policy)
      end)
    end
  end

  test "B06 :warn logs once per feature per node and again for a different feature" do
    reset_warnings()

    in_policy(:warn, fn ->
      tenant = subscribed()

      first =
        capture_log(fn ->
          AuroraMeter.check(tenant, :warn_once_a)
          AuroraMeter.check(tenant, :warn_once_a)
          AuroraMeter.allowed?(tenant, :warn_once_a)
          AuroraMeter.quota(tenant, :warn_once_a)
        end)

      assert occurrences(first, "feature :warn_once_a is not declared") == 1

      second = capture_log(fn -> AuroraMeter.check(tenant, :warn_once_b) end)
      assert occurrences(second, "feature :warn_once_b is not declared") == 1
    end)
  end

  test "B06 the warning is emitted regardless of the Mix environment the library was compiled in" do
    # The old warning sat behind `if Mix.env() == :dev`, evaluated when the host
    # compiled the dependency, so a release build warned about nothing. This
    # library is compiled in :test here and the warning still fires, and the
    # compile-time branch is gone from the source (matched by content, never by
    # line number).
    assert Mix.env() == :test

    code =
      "lib/aurora_meter/entitlements.ex"
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("#")))

    refute Enum.any?(code, &String.contains?(&1, "Mix.env"))

    reset_warnings()

    log =
      capture_log(fn ->
        ConfigSchema.warn_once(:undeclared_feature, :any_env, fn -> "warned about <any_env>" end)
      end)

    assert log =~ "warned about <any_env>"
  end

  test "B06 warnings stop after 128 distinct features with one suppression notice" do
    reset_warnings()
    limit = ConfigSchema.warn_limit()
    assert limit == 128

    log =
      capture_log(fn ->
        for i <- 1..(limit + 3) do
          ConfigSchema.warn_once(:cap_scope, i, fn -> "warned about <#{i}>" end)
        end
      end)

    warned = for i <- 1..(limit + 3), log =~ "warned about <#{i}>", do: i

    assert length(warned) == limit
    assert occurrences(log, "further cap_scope warnings are suppressed") == 1
  end

  test "B07 track/4 counts an undeclared feature under every policy and reports declared: false" do
    for policy <- @policies do
      in_policy(policy, fn ->
        tenant = subscribed()
        attach([:aurora_meter, :track], tenant)

        assert AuroraMeter.track(tenant, :nowhere, 3) == :ok
        assert_receive {:telemetry, [:aurora_meter, :track], %{count: 3}, %{declared: false}}
        assert AuroraMeter.usage(tenant, :nowhere) == 3

        assert AuroraMeter.track(tenant, :policy_hard, 2) == :ok
        assert_receive {:telemetry, [:aurora_meter, :track], %{count: 2}, %{declared: true}}
      end)
    end
  end

  test "reserve telemetry reports declared: false for an undeclared feature" do
    in_policy(:deny, fn ->
      tenant = subscribed()
      attach([:aurora_meter, :reserve], tenant)

      assert AuroraMeter.reserve(tenant, :nowhere, 1) == {:error, :not_entitled}

      assert_receive {:telemetry, [:aurora_meter, :reserve], %{qty: 1},
                      %{declared: false, result: :not_entitled}}

      assert AuroraMeter.reserve(tenant, :policy_hard, 1) == :ok

      assert_receive {:telemetry, [:aurora_meter, :reserve], %{qty: 1},
                      %{declared: true, result: :ok}}
    end)
  end

  test "I04 denial under :deny never reserves" do
    in_policy(:deny, fn ->
      tenant = subscribed()
      assert AuroraMeter.usage(tenant, :nowhere) == 0

      for _ <- 1..50 do
        assert AuroraMeter.reserve(tenant, :nowhere, 1) == {:error, :not_entitled}
      end

      assert AuroraMeter.usage(tenant, :nowhere) == 0

      for _ <- 1..50 do
        assert AuroraMeter.with_quota(tenant, :nowhere, 1, fn -> flunk("ran") end) ==
                 {:error, :not_entitled}
      end

      assert AuroraMeter.usage(tenant, :nowhere) == 0
    end)
  end

  test "I04 declared-feature reservation is policy-invariant" do
    # 01c's concurrency assertion, re-run under all four policies: a branch in
    # front of the reservation must not change the reservation's arithmetic.
    for policy <- @policies do
      in_policy(policy, fn ->
        tenant = subscribed()

        results =
          1..60
          |> Task.async_stream(
            fn _ -> AuroraMeter.with_quota(tenant, :policy_hard, fn -> :done end) end,
            max_concurrency: 20,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.count(results, &match?({:ok, :done}, &1)) == 50
        assert Enum.count(results, &match?({:error, :limit_exceeded}, &1)) == 10
        assert AuroraMeter.usage(tenant, :policy_hard) == 50
      end)
    end
  end

  test ":raise carries feature, tenant key, plan id and entry point in the exception" do
    in_policy(:raise, fn ->
      tenant = subscribed()

      error = assert_raise(UndeclaredFeatureError, fn -> AuroraMeter.check(tenant, :nowhere) end)

      assert error.feature == :nowhere
      assert error.tenant_key == tenant
      assert error.plan_id == :policy
      assert error.entry_point == :check
      assert error.reason == :unknown_feature
      assert error.message =~ "undeclared_feature_policy: :allow"

      for entry_point <- @entry_points -- [:track] do
        raised =
          assert_raise(UndeclaredFeatureError, fn -> call(entry_point, tenant, :nowhere) end)

        assert raised.entry_point == entry_point
      end
    end)
  end

  test "a feature declared on another plan is denied for a tenant whose plan omits it, with reason :not_in_plan" do
    in_policy(:deny, fn ->
      tenant = subscribed()

      # :policy_other declares it; the tenant is on :policy, which does not.
      assert AuroraMeter.check(tenant, :elsewhere) == {:error, :not_entitled}
      assert AuroraMeter.Plans.declared_anywhere?(:elsewhere)
      refute AuroraMeter.Plans.declared_anywhere?(:nowhere)
    end)

    in_policy(:raise, fn ->
      tenant = subscribed()

      error =
        assert_raise(UndeclaredFeatureError, fn -> AuroraMeter.entitled?(tenant, :elsewhere) end)

      assert error.reason == :not_in_plan
      assert error.message =~ "Another plan declares it"
    end)
  end

  # -- helpers ---------------------------------------------------------------

  defp assert_case(policy, feature, entry_point, expected) do
    in_policy(policy, fn ->
      tenant = subscribed()
      assert_entry_point(tenant, feature, entry_point, expected)
    end)
  end

  defp assert_entry_point(tenant, feature, entry_point, expected) do
    case expectation(entry_point, feature, expected) do
      :raises ->
        assert_raise UndeclaredFeatureError, fn -> call(entry_point, tenant, feature) end
        assert AuroraMeter.usage(tenant, feature) == 0
        refute_received :ran

      value ->
        assert call(entry_point, tenant, feature) == value
        assert_effect(entry_point, tenant, feature, expected)
    end
  end

  defp expectation(:quota, feature, expected) do
    case expected.quota do
      :raises -> :raises
      quota -> Map.put(quota, :feature, feature)
    end
  end

  defp expectation(entry_point, _feature, expected), do: Map.fetch!(expected, entry_point)

  defp assert_effect(:reserve, tenant, feature, expected) do
    assert AuroraMeter.usage(tenant, feature) == expected.reserved
  end

  defp assert_effect(:with_quota, tenant, feature, expected) do
    if expected.ran? do
      assert_received :ran
      assert AuroraMeter.usage(tenant, feature) == 1
    else
      refute_received :ran
      assert AuroraMeter.usage(tenant, feature) == 0
    end
  end

  defp assert_effect(:track, tenant, feature, _expected) do
    assert AuroraMeter.usage(tenant, feature) == 3
  end

  defp assert_effect(_entry_point, tenant, feature, _expected) do
    assert AuroraMeter.usage(tenant, feature) == 0
  end

  defp call(:check, tenant, feature), do: AuroraMeter.check(tenant, feature)
  defp call(:allowed?, tenant, feature), do: AuroraMeter.allowed?(tenant, feature)
  defp call(:entitled?, tenant, feature), do: AuroraMeter.entitled?(tenant, feature)

  defp call(:feature_value, tenant, feature),
    do: AuroraMeter.feature_value(tenant, feature, :no_value)

  defp call(:quota, tenant, feature),
    do: tenant |> AuroraMeter.quota(feature) |> Map.delete(:period)

  defp call(:remaining, tenant, feature), do: AuroraMeter.remaining(tenant, feature)
  defp call(:reserve, tenant, feature), do: AuroraMeter.reserve(tenant, feature, 1)

  defp call(:with_quota, tenant, feature) do
    parent = self()
    AuroraMeter.with_quota(tenant, feature, 1, fn -> send(parent, :ran) && :ran end)
  end

  defp call(:track, tenant, feature), do: AuroraMeter.track(tenant, feature, 3)

  defp assert_shapes(tenant, feature, :raise) do
    for entry_point <- @entry_points -- [:track] do
      assert_raise UndeclaredFeatureError, fn -> call(entry_point, tenant, feature) end
    end

    assert call(:track, tenant, feature) == :ok
  end

  defp assert_shapes(tenant, feature, _policy) do
    assert call(:check, tenant, feature) in [:ok, {:error, :not_entitled}]
    assert is_boolean(call(:allowed?, tenant, feature))
    assert is_boolean(call(:entitled?, tenant, feature))
    assert call(:feature_value, tenant, feature) == :no_value

    remaining = call(:remaining, tenant, feature)
    assert remaining == :unlimited or (is_integer(remaining) and remaining >= 0)

    quota = AuroraMeter.quota(tenant, feature)
    assert quota |> Map.keys() |> Enum.sort() == Enum.sort(@quota_keys)
    assert quota.kind == :undeclared
    assert is_boolean(quota.enabled)
    assert %{start: %DateTime{}, end: %DateTime{}, source: _} = quota.period

    assert call(:reserve, tenant, feature) in [:ok, {:error, :not_entitled}]
    assert call(:with_quota, tenant, feature) in [{:ok, :ran}, {:error, :not_entitled}]
    flush_ran()
    assert call(:track, tenant, feature) == :ok
  end

  defp in_policy(policy, fun) do
    with_config(
      [
        {:aurora_meter, :plans, AuroraMeter.Test.PolicyPlans},
        {:aurora_meter, :undeclared_feature_policy, policy}
      ],
      fun
    )
  end

  defp subscribed do
    tenant = unique_tenant()
    {:ok, _subscription} = AuroraMeter.subscribe(tenant, :policy)
    tenant
  end

  defp attach(event, tenant) do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(id, event, &__MODULE__.handle_event/4, %{parent: self(), tenant: tenant})

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp reset_warnings do
    ConfigSchema.reset_warnings!()
    on_exit(&ConfigSchema.reset_warnings!/0)
  end

  defp flush_ran do
    receive do
      :ran -> :ok
    after
      0 -> :ok
    end
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
