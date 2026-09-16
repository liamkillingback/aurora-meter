defmodule AuroraMeter.PlanVersionsTest do
  @moduledoc """
  Plan version identity, the snapshot registry and the legacy assignment
  (build unit 07a, V1 tasks 07.01, 07.02 and 07.03; invariant I17).

  `async: false` throughout: every test either freezes the clock, swaps the
  plans module, or writes `:persistent_term`, and all three are node wide.

  Compile-time failures are asserted with `Code.eval_string/1` inside
  `assert_raise`, which is how a DSL error is testable without breaking the
  suite's own compilation.
  """
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test, only: [with_clock: 2, travel: 1]
  import AuroraMeter.Test.Config, only: [with_config: 2]
  import ExUnit.CaptureLog

  alias AuroraMeter.Config.Schema, as: ConfigSchema
  alias AuroraMeter.Entitlements
  alias AuroraMeter.Plan
  alias AuroraMeter.Plans
  alias AuroraMeter.Plans.Snapshot
  alias AuroraMeter.PlanVersionConflictError
  alias AuroraMeter.Schema.PlanVersion
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage

  # `:versioned` version 2 becomes effective here, and `AuroraMeter.TestPlans`
  # dates it there.
  @boundary ~U[2030-01-01 00:00:00Z]
  @before_boundary ~U[2029-12-31 23:59:59Z]
  @after_boundary ~U[2030-01-01 00:00:01Z]

  setup do
    # The registry and its snapshot cache are `:persistent_term`, which is node
    # wide and outlives a sandbox rollback. Every test in this file starts from
    # the state a fresh node has and leaves it that way.
    on_exit(fn ->
      Plans.reset_registry()
      ConfigSchema.reset_warnings!()
    end)

    :ok
  end

  # -- the DSL ----------------------------------------------------------------

  test "I17 a plan block without a version compiles as version 1 with no effective instant" do
    plan = Plans.get(:pro)

    assert plan.version == "1"
    assert plan.effective_at == nil
    assert plan.fingerprint == Snapshot.fingerprint(%{plan | fingerprint: nil})
  end

  test "I17 two versions of one plan id both compile and versions/1 lists them oldest first" do
    assert [one, two] = Plans.versions(:versioned)

    assert one.version == "1"
    assert one.effective_at == nil
    assert one.price == 2_000

    assert two.version == "2"
    assert two.effective_at == @boundary
    assert two.price == 3_000
  end

  test "I17 duplicate plan id and version in one module raises at compile time" do
    message =
      compile_error("""
      plan :dup do
        price 1
      end

      plan :dup, version: "1" do
        price 2
      end
      """)

    assert message =~ "declares the same plan version twice"
    assert message =~ ":dup version \"1\""
  end

  test "I17 two versions of one plan with the same effective instant raise at compile time" do
    message =
      compile_error("""
      plan :same do
        price 1
      end

      plan :same, version: "2" do
        price 2
      end
      """)

    assert message =~ "two versions effective at the same instant"
    assert message =~ ":same"
  end

  test "I17 a plan id whose only version is future dated raises at compile time" do
    message =
      compile_error("""
      plan :future, version: "2", effective_at: ~U[2030-01-01 00:00:00Z] do
        price 1
      end
      """)

    assert message =~ "has no base version"
    assert message =~ "Give its earliest version no :effective_at"
  end

  test "I17 an invalid version string raises at compile time" do
    assert compile_error("""
           plan :bad, version: "a b" do
             price 1
           end
           """) =~ "has invalid version \"a b\""

    assert compile_error("""
           plan :bad, version: :two do
             price 1
           end
           """) =~ "a version is a string"

    assert compile_error("""
           plan :bad, version: "0123456789012345678901234567890123" do
             price 1
           end
           """) =~ "has invalid version"
  end

  test "I17 a non-UTC effective instant raises at compile time and says why" do
    message =
      compile_error("""
      plan :bad, version: "2", effective_at: ~N[2030-01-01 00:00:00] do
        price 1
      end
      """)

    assert message =~ "has invalid :effective_at"
    assert message =~ "does not convert time zones on a commercial boundary"
  end

  test "I17 an unknown option in the plan keyword list raises and lists the accepted keys" do
    message =
      compile_error("""
      plan :bad, verison: "2" do
        price 1
      end
      """)

    assert message =~ "unknown option(s) [:verison]"
    assert message =~ "[:version, :effective_at]"
  end

  # -- resolution -------------------------------------------------------------

  test "I17 a future-dated version is not effective before its instant and is after it" do
    with_clock(@before_boundary, fn ->
      assert Plans.get(:versioned).version == "1"
      assert Plans.get(:versioned).price == 2_000
      assert Plans.all()[:versioned].version == "1"
      assert Plans.feature_config(:versioned, :ai_generations) == {:limit, 1_000, :hard}

      travel(@after_boundary)

      assert Plans.get(:versioned).version == "2"
      assert Plans.get(:versioned).price == 3_000
      assert Plans.all()[:versioned].version == "2"
      assert Plans.feature_config(:versioned, :ai_generations) == {:limit, 2_000, :hard}
    end)
  end

  test "I17 all/0 keeps its %{id => plan} shape" do
    plans = Plans.all()

    assert is_map(plans)
    assert %Plan{id: :free} = plans[:free]
    assert Enum.all?(plans, fn {id, plan} -> is_atom(id) and plan.id == id end)
  end

  test "I17 base/1 is the version with no effective instant, whatever the clock says" do
    with_clock(@after_boundary, fn ->
      assert Plans.get(:versioned).version == "2"
      assert Plans.base(:versioned).version == "1"
    end)
  end

  test "I17 get/2 returns a compiled version and nil for a version in neither code nor storage" do
    assert Plans.get(:versioned, "1").price == 2_000
    assert Plans.get(:versioned, "2").price == 3_000
    assert Plans.get(:versioned, "no-such-version") == nil
    assert Plans.get(:no_such_plan, "1") == nil
  end

  # -- the registry -----------------------------------------------------------

  test "I17 register! stores one snapshot per compiled version and the second run writes nothing" do
    clear_registry!()

    assert :ok = Plans.register!()
    first = stored()

    compiled = AuroraMeter.TestPlans.__aurora_plans__()
    assert length(first) == map_size(compiled)

    for {{id, version}, plan} <- compiled do
      row = Enum.find(first, &(&1.plan_id == Atom.to_string(id) and &1.version == version))
      assert row, "no snapshot for #{id} version #{version}"
      assert row.fingerprint == plan.fingerprint
      assert row.effective_at == plan.effective_at
      assert row.definition["fingerprint_version"] == Snapshot.fingerprint_version()
    end

    assert :ok = Plans.register!()

    # Same rows, same ids: the second run inserted nothing, rather than
    # inserting and deleting or replacing.
    assert Enum.map(stored(), & &1.id) |> Enum.sort() ==
             Enum.map(first, & &1.id) |> Enum.sort()
  end

  test "I17 register! stamps first_seen_at from the database, not from the node clock" do
    clear_registry!()

    # A frozen node clock decades in the past. If the row were stamped from it,
    # `first_seen_at` would be 2020.
    with_clock(~U[2020-01-01 00:00:00Z], fn -> assert :ok = Plans.register!() end)

    row = hd(stored())
    assert DateTime.compare(row.first_seen_at, ~U[2024-01-01 00:00:00Z]) == :gt
  end

  test "I17 register! raises PlanVersionConflictError naming the plan, version and both fingerprints" do
    clear_registry!()
    assert :ok = Plans.register!()

    stored_fingerprint = fingerprint_of("versioned", "1")
    compiled_fingerprint = Plans.get(:versioned, "1").fingerprint
    assert stored_fingerprint == compiled_fingerprint

    # `:raise` explicitly: this package is 0.5.x, where the default is `:warn`
    # so that an upgrading host meets a log line before it meets a failed
    # deploy. `:raise` is the default from 1.0 and is what this test is about.
    error =
      with_config(
        [
          {:aurora_meter, :plan_version_conflict, :raise},
          {:aurora_meter, :plans, AuroraMeter.Test.EditedVersionPlans}
        ],
        fn -> assert_raise PlanVersionConflictError, fn -> Plans.register!() end end
      )

    assert [conflict] = error.conflicts
    assert conflict.plan_id == "versioned"
    assert conflict.version == "1"
    assert conflict.stored_fingerprint == stored_fingerprint
    refute conflict.compiled_fingerprint == stored_fingerprint

    message = Exception.message(error)
    assert message =~ "plan versioned version 1"
    assert message =~ Snapshot.short(stored_fingerprint)
    assert message =~ Snapshot.short(conflict.compiled_fingerprint)
    assert message =~ "Publish the change as a new version instead"
    assert message =~ "plan :versioned, version: \"2\""
    assert message =~ "SELECT plan_id, version, encode(fingerprint, 'hex'), definition"

    # And nothing was rewritten: the stored definition is still the one the
    # tenant was sold.
    assert fingerprint_of("versioned", "1") == stored_fingerprint
  end

  test "I17 plan_version_conflict warn logs the same message once and does not raise" do
    clear_registry!()
    assert :ok = Plans.register!()

    # One `with_config/2` region, not two nested: the harness holds a single
    # token per region and a nested call from the same process waits on itself.
    log =
      with_config(
        [
          {:aurora_meter, :plan_version_conflict, :warn},
          {:aurora_meter, :plans, AuroraMeter.Test.EditedVersionPlans}
        ],
        fn -> capture_log(fn -> assert :ok = Plans.register!() end) end
      )

    assert log =~ "[error]"
    assert log =~ "plan versioned version 1"
    assert log =~ "Publish the change as a new version instead"
  end

  test "I17 a storage adapter without snapshot support warns once and leaves code authoritative" do
    clear_registry!()

    log =
      with_config([{:aurora_meter, :storage, AuroraMeter.Test.IncapableStorage}], fn ->
        capture_log(fn -> assert :ok = Plans.register!() end)
      end)

    assert log =~ "does not support :plan_versions"
    assert log =~ "Keep every referenced version in code"
    assert Plans.registry_state() == :unsupported

    # Code is still the authority, which is the documented degraded mode.
    assert Plans.get(:versioned, "1").price == 2_000
  end

  # -- legacy assignment (D05) ------------------------------------------------

  test "I17 register! names the contract of a subscription that has none, and leaves a named one alone" do
    clear_registry!()
    assert :ok = Plans.register!()

    unnamed = subscribe!(:versioned)
    named = subscribe!(:versioned, version: "2")
    unname!(unnamed)

    assert row(unnamed).plan_version == nil
    assert row(named).plan_version == "2"

    assert :ok = Plans.register!()

    assigned = row(unnamed)
    assert assigned.plan_version == "1"
    assert assigned.plan_fingerprint == Plans.get(:versioned, "1").fingerprint
    assert assigned.plan_id == "versioned"

    # L17.4: a row that already names its contract is never rewritten.
    assert row(named).plan_version == "2"
    assert row(named).plan_fingerprint == Plans.get(:versioned, "2").fingerprint
  end

  test "I17 register! names a subscription whose plan id is in no compiled module, with no fingerprint" do
    clear_registry!()
    assert :ok = Plans.register!()

    orphan = unique_tenant("planorphan")

    {:ok, _} =
      Storage.put_subscription(%{
        tenant_key: orphan,
        plan_id: "unknown",
        status: "active"
      })

    assert :ok = Plans.register!()

    assigned = row(orphan)
    assert assigned.plan_version == "1"
    assert assigned.plan_fingerprint == nil
    assert assigned.plan_id == "unknown"
  end

  test "I17 the legacy assignment names the plan's base version, not the literal 1" do
    # The control that found this: with the assignment joining on `version = '1'`
    # instead of on the base version, the whole rest of this file still passed,
    # because every version in `AuroraMeter.TestPlans` that has no
    # `effective_at` is also called `"1"` (finding X287). A host that named its
    # first version `"2024-01"` would have had every tenant pinned to a version
    # that has never existed, and they would all have fallen back to the default
    # plan at the next entitlement read.
    tenant = unique_tenant("planrenamed")

    with_config([{:aurora_meter, :plans, AuroraMeter.Test.RenamedBaseVersionPlans}], fn ->
      clear_registry!()
      assert :ok = Plans.register!()

      {:ok, _} =
        Storage.put_subscription(%{tenant_key: tenant, plan_id: "renamed", status: "active"})

      unname!(tenant)
      assert :ok = Plans.register!()

      assigned = row(tenant)

      assert assigned.plan_version == "2024-01",
             "the tenant was pinned to #{inspect(assigned.plan_version)}, which is not a " <>
               "version :renamed has ever had"

      assert assigned.plan_fingerprint == Plans.get(:renamed, "2024-01").fingerprint

      AuroraMeter.Subscriptions.invalidate(tenant)
      assert AuroraMeter.plan(tenant).id == :renamed
      assert AuroraMeter.quota(tenant, :ai_generations).limit == 300
    end)
  end

  test "I17 the legacy assignment takes plan_effective_at from the past, never from the upgrade clock" do
    clear_registry!()
    assert :ok = Plans.register!()

    tenant = subscribe!(:versioned)
    unname!(tenant)
    inserted_at = row(tenant).inserted_at

    # Registration decades later must not claim the assignment started then.
    with_clock(~U[2035-06-01 00:00:00Z], fn -> assert :ok = Plans.register!() end)

    effective_at = row(tenant).plan_effective_at
    assert effective_at

    # Within a second of the subscription's own `inserted_at`: the column is a
    # `timestamp(0)`, and Postgres **rounds** rather than truncates on the cast,
    # so an exact equality here would be a coin flip on the sub-second part.
    assert abs(DateTime.diff(effective_at, inserted_at, :second)) <= 1

    # And decades away from the clock the registration ran under, which is the
    # assertion that carries the claim.
    assert DateTime.compare(effective_at, ~U[2030-01-01 00:00:00Z]) == :lt
  end

  test "I17 a tenant subscribed before version 2 exists keeps version 1 after version 2 is effective" do
    clear_registry!()
    assert :ok = Plans.register!()

    tenant = subscribe!(:versioned)

    before = %{
      version: AuroraMeter.plan(tenant).version,
      price: AuroraMeter.plan(tenant).price,
      quota: AuroraMeter.quota(tenant, :ai_generations).limit,
      seats: AuroraMeter.feature_value(tenant, :seats),
      api_access: AuroraMeter.entitled?(tenant, :api_access),
      credits: credit_amounts(AuroraMeter.plan(tenant))
    }

    assert before == %{
             version: "1",
             price: 2_000,
             quota: 1_000,
             seats: 5,
             api_access: true,
             credits: [{:monthly, 5_000_000, 1_000_000}]
           }

    # Deploy: version 2 is now effective, and nothing about the tenant's row
    # changed. This is G07 bullet 1's core half.
    with_plans(AuroraMeter.Test.VersionTwoLivePlans, fn ->
      assert Plans.get(:versioned).version == "2"
      AuroraMeter.Subscriptions.invalidate(tenant)

      assert AuroraMeter.plan(tenant).version == "1"
      assert AuroraMeter.plan(tenant).price == before.price
      assert AuroraMeter.quota(tenant, :ai_generations).limit == before.quota
      assert AuroraMeter.feature_value(tenant, :seats) == before.seats
      assert AuroraMeter.entitled?(tenant, :api_access) == before.api_access
      assert credit_amounts(AuroraMeter.plan(tenant)) == before.credits
    end)

    assert row(tenant).plan_version == "1"
  end

  test "I17 a tenant keeps version 1's limits when version 1's block is deleted from the module" do
    clear_registry!()
    assert :ok = Plans.register!()

    tenant = subscribe!(:versioned)
    assert AuroraMeter.plan(tenant).version == "1"

    # The whole point of persisting snapshots: version 1 is gone from code and
    # the only definition left for `:versioned` is version 2.
    log =
      with_plans(AuroraMeter.Test.VersionOneDeletedPlans, fn ->
        AuroraMeter.Subscriptions.invalidate(tenant)
        assert Plans.get(:versioned, "1") == nil_or_snapshot()

        capture_log(fn ->
          plan = AuroraMeter.plan(tenant)

          assert plan.version == "1"
          assert plan.price == 2_000
          assert plan.features[:ai_generations] == {:limit, 1_000, :hard}
          assert plan.features[:seats] == {:feature, 5}
          assert credit_amounts(plan) == [{:monthly, 5_000_000, 1_000_000}]

          assert AuroraMeter.quota(tenant, :ai_generations).limit == 1_000
          assert AuroraMeter.feature_value(tenant, :seats) == 5
        end)
      end)

    # No error other than the documented dropped-feature one, and there are no
    # dropped features here.
    refute log =~ "[error]"
    refute log =~ "which no atom on this node matches"
  end

  test "I17 a subscription pinned to a version in neither code nor storage falls back and says so" do
    clear_registry!()
    assert :ok = Plans.register!()

    tenant = subscribe!(:versioned)
    pin!(tenant, "retired-and-unregistered")
    AuroraMeter.Subscriptions.invalidate(tenant)

    log = capture_log(fn -> assert AuroraMeter.plan(tenant).id == :free end)

    assert log =~ "pinned to plan :versioned version \"retired-and-unregistered\""
    assert log =~ "resolves to the default plan"
  end

  # -- subscribe/3 ------------------------------------------------------------

  test "I17 subscribe/2 selects the version effective now and stamps its fingerprint" do
    tenant = unique_tenant("plansub")

    with_clock(@before_boundary, fn ->
      assert {:ok, _} = AuroraMeter.subscribe(tenant, :versioned)
      assert row(tenant).plan_version == "1"
      assert row(tenant).plan_fingerprint == Plans.get(:versioned, "1").fingerprint
    end)

    other = unique_tenant("plansub")

    with_clock(@after_boundary, fn ->
      assert {:ok, _} = AuroraMeter.subscribe(other, :versioned)
      assert row(other).plan_version == "2"
      assert row(other).plan_fingerprint == Plans.get(:versioned, "2").fingerprint
    end)
  end

  test "I17 subscribe/3 with an explicit version pins it, including one not yet effective" do
    tenant = unique_tenant("plansub")

    with_clock(@after_boundary, fn ->
      assert {:ok, _} = AuroraMeter.subscribe(tenant, :versioned, version: "1")
      assert row(tenant).plan_version == "1"
      assert AuroraMeter.plan(tenant).price == 2_000
    end)

    early = unique_tenant("plansub")

    with_clock(@before_boundary, fn ->
      # An explicit opt-in is not a future-dated version becoming active early:
      # the caller asked for it by name.
      assert {:ok, _} = AuroraMeter.subscribe(early, :versioned, version: "2")
      assert row(early).plan_version == "2"
      assert AuroraMeter.plan(early).price == 3_000

      # And the plan id still resolves to version 1 for everyone else.
      assert Plans.get(:versioned).version == "1"
    end)
  end

  test "I17 subscribe/3 with an unknown version is a changeset error naming plan_version" do
    tenant = unique_tenant("plansub")

    assert {:error, changeset} = AuroraMeter.subscribe(tenant, :versioned, version: "99")
    assert errors_on(changeset)[:plan_version] == ["is not a known version of this plan"]
    assert Storage.get_subscription(tenant) == nil
  end

  # -- S4, the replace list ---------------------------------------------------

  test "I17 put_subscription with a partial attribute map leaves every column it did not send" do
    tenant = subscribe!(:versioned, version: "2")
    schedule!(tenant)

    before = row(tenant)
    assert before.plan_version == "2"
    assert before.plan_fingerprint
    assert before.scheduled_plan_id == "versioned"
    assert before.transition_ref == "ref-1"

    # What `AuroraMeter.Pro.Subscriptions.sync/1` sends: a plan id, a status and
    # provider identity, and nothing else.
    assert {:ok, _} =
             Storage.put_subscription(%{
               tenant_key: tenant,
               plan_id: "versioned",
               status: "active",
               provider: "stripe",
               provider_customer_id: "cus_1",
               provider_subscription_id: "sub_1"
             })

    after_sync = row(tenant)

    assert after_sync.plan_version == before.plan_version
    assert after_sync.plan_fingerprint == before.plan_fingerprint
    assert after_sync.plan_effective_at == before.plan_effective_at
    assert after_sync.scheduled_plan_id == before.scheduled_plan_id
    assert after_sync.scheduled_plan_version == before.scheduled_plan_version
    assert after_sync.scheduled_effective_at == before.scheduled_effective_at
    assert after_sync.transition_ref == before.transition_ref
    assert after_sync.transition_state == before.transition_state
    assert after_sync.transition_confirm == before.transition_confirm

    # And what it did send is written.
    assert after_sync.provider == "stripe"
    assert after_sync.provider_subscription_id == "sub_1"
  end

  test "I17 put_subscription never writes a transition column, even when asked to" do
    tenant = subscribe!(:versioned, version: "2")
    schedule!(tenant)

    assert {:ok, _} =
             Storage.put_subscription(%{
               tenant_key: tenant,
               plan_id: "versioned",
               status: "active",
               transition_ref: "ref-hijacked",
               transition_state: "applied",
               scheduled_plan_id: "free"
             })

    kept = row(tenant)
    assert kept.transition_ref == "ref-1"
    assert kept.transition_state == "pending"
    assert kept.scheduled_plan_id == "versioned"
  end

  test "I17 put_subscription with a full provider attribute map updates every syncable column" do
    tenant = subscribe!(:versioned, version: "1")

    assert {:ok, _} =
             Storage.put_subscription(%{
               tenant_key: tenant,
               plan_id: "free",
               status: "canceled",
               provider: "stripe",
               provider_customer_id: "cus_2",
               provider_subscription_id: "sub_2",
               current_period_start: ~U[2026-01-01 00:00:00Z],
               current_period_end: ~U[2026-02-01 00:00:00Z],
               plan_version: "1",
               plan_fingerprint: Plans.get(:free, "1").fingerprint,
               plan_effective_at: ~U[2026-01-01 00:00:00Z]
             })

    updated = row(tenant)
    assert updated.plan_id == "free"
    assert updated.status == "canceled"
    assert updated.provider_customer_id == "cus_2"
    assert updated.current_period_end == ~U[2026-02-01 00:00:00Z]
    assert updated.plan_fingerprint == Plans.get(:free, "1").fingerprint
  end

  test "I17 put_subscription still invalidates the subscription cache" do
    tenant = subscribe!(:versioned, version: "1")
    assert AuroraMeter.plan(tenant).price == 2_000

    assert {:ok, _} =
             Storage.put_subscription(%{
               tenant_key: tenant,
               plan_id: "free",
               status: "active",
               plan_version: "1",
               plan_fingerprint: Plans.get(:free, "1").fingerprint
             })

    assert AuroraMeter.plan(tenant).id == :free
  end

  # -- helpers ----------------------------------------------------------------

  defp clear_registry! do
    TestRepo.delete_all(PlanVersion)
    Plans.reset_registry()
    :ok
  end

  defp stored, do: TestRepo.all(PlanVersion)

  defp fingerprint_of(plan_id, version) do
    row = Enum.find(stored(), &(&1.plan_id == plan_id and &1.version == version))
    row && row.fingerprint
  end

  defp row(tenant_key), do: TestRepo.get_by!(Subscription, tenant_key: tenant_key)

  defp subscribe!(plan_id, opts \\ []) do
    tenant = unique_tenant("planver")

    with_clock(@before_boundary, fn ->
      {:ok, _} = Entitlements.subscribe(tenant, plan_id, opts)
    end)

    tenant
  end

  # The shape a pre-version-10 row has: the columns exist and are NULL.
  defp unname!(tenant_key) do
    {1, _} =
      TestRepo.update_all(
        from(s in Subscription, where: s.tenant_key == ^tenant_key),
        set: [plan_version: nil, plan_fingerprint: nil, plan_effective_at: nil]
      )

    AuroraMeter.Subscriptions.invalidate(tenant_key)
    :ok
  end

  defp pin!(tenant_key, version) do
    {1, _} =
      TestRepo.update_all(
        from(s in Subscription, where: s.tenant_key == ^tenant_key),
        set: [plan_version: version]
      )

    :ok
  end

  # 07b owns every write to these columns. This is the only place in the suite
  # that sets them, and it sets them directly so the S4 tests have something a
  # sync must not touch.
  defp schedule!(tenant_key) do
    {1, _} =
      TestRepo.update_all(
        from(s in Subscription, where: s.tenant_key == ^tenant_key),
        set: [
          scheduled_plan_id: "versioned",
          scheduled_plan_version: "2",
          scheduled_effective_at: ~U[2030-01-01 00:00:00Z],
          transition_ref: "ref-1",
          transition_state: "pending",
          transition_confirm: "provider"
        ]
      )

    :ok
  end

  defp credit_amounts(plan),
    do: Enum.map(plan.recurring_credits, &{&1.name, &1.amount, &1.rollover})

  defp with_plans(module, fun),
    do: with_config([{:aurora_meter, :plans, module}], fun)

  # `Plans.get(:versioned, "1")` with version 1 deleted resolves from storage,
  # and the point of the assertion is that it is NOT nil. Written this way so
  # the test reads as "it is the snapshot" rather than as a bare refute.
  defp nil_or_snapshot do
    plan = Plans.get(:versioned, "1")
    assert plan, "version 1 should have resolved from the stored snapshot"
    plan
  end

  defp compile_error(body) do
    module = "AuroraMeterPlanVersions#{System.unique_integer([:positive])}"

    Exception.message(
      catch_error(
        Code.eval_string("""
        defmodule #{module} do
          use AuroraMeter.Plans
        #{body}
        end
        """)
      )
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
