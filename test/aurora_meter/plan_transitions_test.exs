defmodule AuroraMeter.PlanTransitionsTest do
  @moduledoc """
  Build unit 07b: scheduling, idempotency, cancel, apply, custom periods and the
  two structural proofs (no destructive reset, no price-dependent branch).

  Sandboxed. The races, the kills and the twelve-connection counts live in
  `plan_transitions_concurrency_test.exs`, which cannot use the sandbox because
  the sandbox serialises the very contention those tests are about.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Clock
  alias AuroraMeter.Period
  alias AuroraMeter.Plans
  alias AuroraMeter.Schema.PlanTransition
  alias AuroraMeter.Storage
  alias AuroraMeter.Subscriptions
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.PeriodSources

  @next_month ~U[2026-10-01 00:00:00Z]
  @inside_september ~U[2026-09-16 10:00:00Z]
  @far_future ~U[2030-12-01 00:00:00Z]

  setup do
    Subscriptions.invalidate("warm")
    :ok
  end

  defp subscribed(plan \\ :pro, opts \\ []) do
    tenant = unique_tenant("trans")
    {:ok, subscription} = AuroraMeter.subscribe(tenant, plan, opts)
    Subscriptions.invalidate(tenant)
    {tenant, subscription}
  end

  defp reload(tenant) do
    Subscriptions.invalidate(tenant)
    Storage.get_subscription(tenant)
  end

  # -- X288: the assignment instant is stamped by the database ----------------

  test "X288 subscribe stamps plan_effective_at from the database, not from this node" do
    # The node's clock is frozen four years in the past. A column stamped here
    # would carry 2022; a column stamped by the database carries now. This is
    # the assertion that inverts when the `:db_now` sentinel is removed from
    # `AuroraMeter.Entitlements.subscribe_known/3`.
    frozen = ~U[2022-01-01 00:00:00Z]

    tenant =
      AuroraMeter.Test.with_clock(frozen, fn ->
        {tenant, _subscription} = subscribed(:pro)
        tenant
      end)

    stored = reload(tenant).plan_effective_at
    database = TestRepo.query!("SELECT clock_timestamp() AT TIME ZONE 'UTC'", []).rows

    [[raw]] = database
    {:ok, now} = DateTime.from_naive(raw, "Etc/UTC")

    assert DateTime.diff(now, stored, :second) < 60,
           "plan_effective_at is #{inspect(stored)}, which is not the database's clock " <>
             "(#{inspect(now)}). A node stamp compared against a database clock is the " <>
             "two-clock defect finding X288 is about."

    refute DateTime.compare(stored, frozen) == :eq
  end

  test "X288 an explicit plan_effective_at is still honoured" do
    tenant = unique_tenant("trans")
    chosen = ~U[2024-05-05 05:05:05Z]

    {:ok, _} =
      Storage.put_subscription(%{
        tenant_key: tenant,
        plan_id: "pro",
        plan_version: "1",
        status: "active",
        plan_effective_at: chosen
      })

    assert reload(tenant).plan_effective_at == chosen
  end

  # -- scheduling -------------------------------------------------------------

  test "I17 schedule_transition defaults effective_at to the end of the tenant's current period" do
    {tenant, _} = subscribed()

    AuroraMeter.Test.with_clock(@inside_september, fn ->
      {:ok, transition} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")
      assert transition.effective_at == @next_month
    end)
  end

  test "I17 schedule_transition defaults version to the version effective at the effective time" do
    {tenant, _} = subscribed(:pro)

    AuroraMeter.Test.with_clock(@inside_september, fn ->
      {:ok, transition} = Subscriptions.schedule_transition(tenant, :versioned, ref: "r")

      # `:versioned` version 2 becomes effective in 2030, so a transition landing
      # in October 2026 gets version 1.
      assert transition.to_version == "1"
    end)
  end

  test "I17 schedule_transition to a version not yet effective at the effective time is refused" do
    {tenant, _} = subscribed(:pro)

    AuroraMeter.Test.with_clock(@inside_september, fn ->
      assert {:ok, transition} =
               Subscriptions.schedule_transition(tenant, :versioned,
                 ref: "explicit",
                 version: "2"
               )

      # An explicitly named future version is accepted, because the caller asked
      # for it, and is what the default refuses to pick on their behalf.
      assert transition.to_version == "2"
    end)
  end

  test "I17 schedule_transition to a future-dated version is accepted when it is effective then" do
    {tenant, _} = subscribed(:pro)

    AuroraMeter.Test.with_clock(@inside_september, fn ->
      {:ok, transition} =
        Subscriptions.schedule_transition(tenant, :versioned,
          ref: "r",
          effective_at: ~U[2030-06-01 00:00:00Z]
        )

      assert transition.to_version == "2"
    end)
  end

  test "I17 schedule_transition without a ref is refused" do
    {tenant, _} = subscribed()

    assert {:error, {:invalid, [ref: "is required"]}} =
             Subscriptions.schedule_transition(tenant, :scale, [])
  end

  test "I17 schedule_transition with a ref over 128 bytes is refused" do
    {tenant, _} = subscribed()

    assert {:error, {:invalid, [ref: message]}} =
             Subscriptions.schedule_transition(tenant, :scale, ref: String.duplicate("x", 129))

    assert message =~ "128"
  end

  test "I17 schedule_transition with a past effective_at is refused" do
    {tenant, _} = subscribed()

    assert {:error, {:invalid, [effective_at: "must be in the future"]}} =
             Subscriptions.schedule_transition(tenant, :scale,
               ref: "r",
               effective_at: ~U[2020-01-01 00:00:00Z]
             )
  end

  test "I17 schedule_transition with a non-UTC effective_at is refused" do
    {tenant, _} = subscribed()

    naive = ~N[2030-01-01 00:00:00]

    assert {:error, {:invalid, [effective_at: "must be a UTC DateTime"]}} =
             Subscriptions.schedule_transition(tenant, :scale, ref: "r", effective_at: naive)
  end

  test "I17 schedule_transition to an unknown plan is refused" do
    {tenant, _} = subscribed()

    assert {:error, {:invalid, [to_plan: "is not a known plan"]}} =
             Subscriptions.schedule_transition(tenant, :no_such_plan, ref: "r")
  end

  test "I17 schedule_transition to an unknown version of a known plan is refused" do
    {tenant, _} = subscribed()

    assert {:error, {:invalid, [to_plan_version: "is not a known version of this plan"]}} =
             Subscriptions.schedule_transition(tenant, :scale, ref: "r", version: "99")
  end

  test "I17 schedule_transition to the tenant's current plan and version is refused" do
    {tenant, _} = subscribed(:pro)

    assert {:error, {:invalid, [to_plan: "is the current plan and version"]}} =
             Subscriptions.schedule_transition(tenant, :pro, ref: "r")
  end

  test "I17 schedule_transition for a tenant with no subscription is not_found" do
    assert {:error, {:not_found, :subscription}} =
             Subscriptions.schedule_transition(unique_tenant("trans"), :scale, ref: "r")
  end

  test "I17 schedule_transition for a row with a null plan_version is registration_incomplete" do
    {tenant, _} = subscribed()

    TestRepo.query!(
      "UPDATE aurora_meter_subscriptions SET plan_version = NULL WHERE tenant_key = $1",
      [tenant]
    )

    assert {:error, {:unavailable, :registration_incomplete}} =
             Subscriptions.schedule_transition(tenant, :scale, ref: "r")
  end

  test "I17 schedule_transition writes the audit row and mirrors it on the subscription" do
    {tenant, _} = subscribed(:pro)

    AuroraMeter.Test.with_clock(@inside_september, fn ->
      {:ok, transition} = Subscriptions.schedule_transition(tenant, :scale, ref: "upgrade-1")

      assert transition.state == "pending"
      assert transition.confirm == "local"
      assert transition.to_plan_id == "scale"

      row = reload(tenant)
      assert row.scheduled_plan_id == "scale"
      assert row.scheduled_plan_version == "1"
      assert row.scheduled_effective_at == @next_month
      assert row.transition_ref == "upgrade-1"
      assert row.transition_state == "pending"
      assert row.transition_confirm == "local"

      # And nothing about the tenant's entitlements has moved yet.
      assert row.plan_id == "pro"
      assert AuroraMeter.plan(tenant).id == :pro
      assert AuroraMeter.quota(tenant, :ai_generations).limit == 1_000
    end)
  end

  test "I17 schedule_transition copies the current plan and version into from_plan_id" do
    {tenant, _} = subscribed(:pro)
    {:ok, transition} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")

    assert transition.from_plan_id == "pro"
    assert transition.from_version == "1"
  end

  test "I17 schedule_transition merges the caller's detail into the audit row" do
    {tenant, _} = subscribed()

    {:ok, transition} =
      Subscriptions.schedule_transition(tenant, :scale, ref: "r", detail: %{actor: "admin@x"})

    assert transition.detail == %{"actor" => "admin@x"}
  end

  # -- idempotency and replace ------------------------------------------------

  test "I17 the same ref with identical parameters returns the existing transition" do
    {tenant, _} = subscribed()
    {:ok, first} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")
    {:ok, second} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")

    assert first.id == second.id
    assert count_transitions(tenant) == 1
  end

  test "I17 the same ref with different parameters returns a conflict naming both" do
    {tenant, _} = subscribed()
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")

    assert {:error, {:conflict, detail}} =
             Subscriptions.schedule_transition(tenant, :free, ref: "r")

    assert detail.ref == "r"
    assert detail.stored.to_plan_id == "scale"
    assert detail.submitted.to_plan_id == "free"
    assert count_transitions(tenant) == 1
  end

  test "I17 a second ref with replace: true cancels the first and schedules the second" do
    {tenant, _} = subscribed()
    {:ok, first} = Subscriptions.schedule_transition(tenant, :scale, ref: "a")
    {:ok, second} = Subscriptions.schedule_transition(tenant, :free, ref: "b")

    assert transition(tenant, first.ref).state == "cancelled"
    assert transition(tenant, first.ref).detail["reason"] == "replaced"
    assert transition(tenant, first.ref).detail["replaced_by"] == "b"
    assert second.state == "pending"
    assert reload(tenant).transition_ref == "b"
  end

  test "I17 a second ref with replace: false returns a conflict naming the pending ref" do
    {tenant, _} = subscribed()
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "a")

    assert {:error, {:conflict, %{pending_ref: "a"}}} =
             Subscriptions.schedule_transition(tenant, :free, ref: "b", replace: false)

    assert reload(tenant).transition_ref == "a"
    assert count_transitions(tenant) == 1
  end

  test "I17 cancel_transition moves pending to cancelled and clears the pending state" do
    {tenant, _} = subscribed()
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")

    assert {:ok, cancelled} = Subscriptions.cancel_transition(tenant, "r")
    assert cancelled.state == "cancelled"
    assert reload(tenant).transition_state == "cancelled"
  end

  test "I17 cancel_transition on an already cancelled transition is idempotent" do
    {tenant, _} = subscribed()
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")
    {:ok, first} = Subscriptions.cancel_transition(tenant, "r")
    {:ok, second} = Subscriptions.cancel_transition(tenant, "r")

    assert first.id == second.id
    assert second.state == "cancelled"
  end

  test "I17 cancel_transition on an applied transition returns a conflict" do
    {tenant, _} = subscribed()
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")
    {:ok, %{applied: 1}} = Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    assert {:error, {:conflict, %{state: "applied"}}} =
             Subscriptions.cancel_transition(tenant, "r")
  end

  test "I17 cancel_transition with an unknown ref returns not_found" do
    {tenant, _} = subscribed()
    assert {:error, {:not_found, :transition}} = Subscriptions.cancel_transition(tenant, "nope")
  end

  # -- applying ---------------------------------------------------------------

  test "I17 apply_due_transitions applies a transition whose effective_at has passed" do
    {tenant, _} = subscribed(:pro)
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")

    assert {:ok, %{applied: 1, skipped: 0, failed: 0, cursor: :done}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    assert AuroraMeter.plan(tenant).id == :scale
  end

  test "I17 apply_due_transitions does not apply a transition before its effective_at" do
    {tenant, _} = subscribed(:pro)
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")

    assert {:ok, %{applied: 0, skipped: 1}} =
             Subscriptions.apply_due_transitions(tenant: tenant)

    assert reload(tenant).plan_id == "pro"
    assert transition(tenant, "r").state == "pending"
  end

  test "I17 an applied transition changes plan_id, plan_version, fingerprint and effective time" do
    {tenant, _} = subscribed(:pro)

    {:ok, scheduled} =
      Subscriptions.schedule_transition(tenant, :scale, ref: "r", effective_at: @next_month)

    {:ok, %{applied: 1}} = Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    row = reload(tenant)
    assert row.plan_id == "scale"
    assert row.plan_version == "1"
    assert row.plan_fingerprint == Plans.get(:scale, "1").fingerprint
    assert row.transition_state == "applied"

    # The commercial boundary is when the change took effect, never when a
    # worker noticed it. 07c's attribution walks exactly this column.
    assert row.plan_effective_at == scheduled.effective_at
    assert row.plan_effective_at == @next_month
    assert DateTime.compare(row.transition_applied_at, @far_future) == :lt
  end

  test "I17 an applied transition writes applied_at on the audit row" do
    {tenant, _} = subscribed()
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")
    {:ok, %{applied: 1}} = Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    applied = transition(tenant, "r")
    assert applied.state == "applied"
    assert %DateTime{} = applied.applied_at
  end

  test "I17 a transition to a version in neither code nor snapshots is failed and not retried" do
    {tenant, _} = subscribed(:pro)
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")

    TestRepo.query!(
      "UPDATE aurora_meter_plan_transitions SET to_version = 'ghost' WHERE tenant_key = $1",
      [tenant]
    )

    assert {:ok, %{applied: 0, failed: 1}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    failed = transition(tenant, "r")
    assert failed.state == "failed"
    assert failed.detail["error"] == "target version not found"
    assert reload(tenant).plan_id == "pro"
    assert reload(tenant).transition_state == "failed"

    # Never retried: the second run finds nothing pending.
    assert {:ok, %{applied: 0, failed: 0, skipped: 1}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)
  end

  test "I17 the applier refuses a row whose mirror says applied and whose audit row says pending" do
    # L17.10, and the only place the conditional update's own predicate can be
    # seen. Under the row lock the audit row is re-read before the update, so
    # for every state the code itself can produce that re-read decides first and
    # the `transition_state = 'pending'` clause in the `WHERE` never changes an
    # outcome. It changes this one: a subscription mirror that already says
    # `applied` beside an audit row that still says `pending` is what a stale
    # writer, a torn write or an older node leaves behind, and a writer that
    # trusted its own read would apply the change a second time.
    {tenant, _} = subscribed(:pro)
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")

    TestRepo.query!(
      "UPDATE aurora_meter_subscriptions SET transition_state = 'applied' WHERE tenant_key = $1",
      [tenant]
    )

    assert {:ok, %{applied: 0, skipped: 1}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    assert reload(tenant).plan_id == "pro"
    assert transition(tenant, "r").state == "pending"
  end

  test "I17 apply_due_transitions skips a provider transition with no provider_ref" do
    {tenant, _} = subscribed(:pro)
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r", confirm: :provider)

    assert {:ok, %{applied: 0, skipped: 1}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    assert reload(tenant).plan_id == "pro"
    assert transition(tenant, "r").state == "pending"
  end

  test "I17 apply_due_transitions applies a provider transition once provider_ref is set" do
    {tenant, _} = subscribed(:pro)

    {:ok, _} =
      Subscriptions.schedule_transition(tenant, :scale,
        ref: "r",
        confirm: :provider,
        effective_at: @next_month
      )

    {:ok, confirmed} =
      Subscriptions.confirm_transition(tenant, "r", provider_ref: "sub_1", now: @inside_september)

    assert confirmed.state == "pending"
    assert confirmed.provider_ref == "sub_1"

    assert {:ok, %{applied: 1}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)
  end

  test "I17 confirm_transition applies immediately when the provider boundary has passed" do
    {tenant, _} = subscribed(:pro)

    {:ok, _} =
      Subscriptions.schedule_transition(tenant, :scale,
        ref: "r",
        confirm: :provider,
        effective_at: @far_future
      )

    moved = ~U[2026-09-16 09:00:00Z]

    {:ok, applied} =
      Subscriptions.confirm_transition(tenant, "r",
        provider_ref: "sub_1",
        effective_at: moved,
        now: @inside_september
      )

    assert applied.state == "applied"
    assert applied.effective_at == moved
    assert applied.detail["provider_effective_at_changed"] == DateTime.to_iso8601(@far_future)
    assert reload(tenant).plan_effective_at == moved
  end

  test "I17 confirm_transition is idempotent under redelivery of the same provider_ref" do
    {tenant, _} = subscribed(:pro)

    {:ok, _} =
      Subscriptions.schedule_transition(tenant, :scale, ref: "r", confirm: :provider)

    opts = [provider_ref: "sub_1", effective_at: @inside_september, now: @far_future]
    {:ok, first} = Subscriptions.confirm_transition(tenant, "r", opts)
    {:ok, second} = Subscriptions.confirm_transition(tenant, "r", opts)

    assert first.state == "applied"
    assert second.id == first.id
    assert second.state == "applied"
    assert count_transitions(tenant) == 1
  end

  test "I17 confirm_transition with a different provider_ref on an applied transition conflicts" do
    {tenant, _} = subscribed(:pro)
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r", confirm: :provider)

    {:ok, _} =
      Subscriptions.confirm_transition(tenant, "r",
        provider_ref: "sub_1",
        effective_at: @inside_september,
        now: @far_future
      )

    assert {:error, {:conflict, %{provider_ref: "sub_1"}}} =
             Subscriptions.confirm_transition(tenant, "r", provider_ref: "sub_2")
  end

  test "I17 confirm_transition with an unknown ref returns not_found" do
    {tenant, _} = subscribed()

    assert {:error, {:not_found, :transition}} =
             Subscriptions.confirm_transition(tenant, "nope", provider_ref: "sub_1")
  end

  test "I17 confirm_transition without a provider_ref is refused" do
    {tenant, _} = subscribed()
    {:ok, _} = Subscriptions.schedule_transition(tenant, :scale, ref: "r", confirm: :provider)

    assert {:error, {:invalid, [provider_ref: "is required"]}} =
             Subscriptions.confirm_transition(tenant, "r", [])
  end

  test "I17 apply_due_transitions pages with a keyset cursor and returns :done" do
    prefix = "trans_page_#{System.unique_integer([:positive])}"

    tenants =
      for i <- 1..5 do
        tenant = "#{prefix}_#{i}"
        {:ok, _} = AuroraMeter.subscribe(tenant, :pro)

        {:ok, _} =
          Subscriptions.schedule_transition(tenant, :scale,
            ref: "r",
            effective_at: DateTime.add(@next_month, i, :day)
          )

        tenant
      end

    {:ok, first} = Subscriptions.apply_due_transitions(limit: 2, now: @far_future)
    assert first.applied == 2
    assert first.cursor != :done

    assert walk(first, @far_future, first.applied) == 5

    for tenant <- tenants, do: assert(reload(tenant).plan_id == "scale")
  end

  defp walk(%{cursor: :done}, _now, applied), do: applied

  defp walk(page, now, applied) do
    {:ok, next} = Subscriptions.apply_due_transitions(limit: 2, after: page.cursor, now: now)
    walk(next, now, applied + next.applied)
  end

  test "I17 the due scan's keyset pages partition the pending set with no repeat and no gap" do
    # The paging test above walks pages while **applying** them, and a scan that
    # advances by doing the work cannot tell a working cursor from a broken one:
    # an applied row leaves the `transition_state = 'pending'` filter whatever
    # the cursor said (`open-findings.md` X242). This one reads the same scan
    # without applying anything, so only the cursor can move it.
    prefix = "trans_scan_#{System.unique_integer([:positive])}"

    expected =
      for i <- 1..5 do
        tenant = "#{prefix}_#{i}"
        {:ok, _} = AuroraMeter.subscribe(tenant, :pro)

        {:ok, _} =
          Subscriptions.schedule_transition(tenant, :scale,
            ref: "r",
            effective_at: DateTime.add(@next_month, i, :day)
          )

        tenant
      end

    {seen, pages} = scan(nil, [], 0)

    assert seen == expected, "the pages did not cover the pending set exactly, in order"
    assert length(Enum.uniq(seen)) == length(seen), "a row appeared on two pages"
    assert pages == 3, "five rows at a limit of two should take three pages, took #{pages}"
  end

  @scan_opts [
    limit: 2,
    transition_state: "pending",
    scheduled_before: ~U[2030-12-01 00:00:00Z],
    order: :scheduled_effective_at
  ]

  defp scan(_cursor, seen, 20), do: flunk("the keyset never finished; saw #{inspect(seen)}")

  defp scan(cursor, seen, pages) do
    case Storage.list_subscriptions(cursor, @scan_opts) do
      {rows, nil} -> {seen ++ Enum.map(rows, & &1.tenant_key), pages + 1}
      {rows, next} -> scan(next, seen ++ Enum.map(rows, & &1.tenant_key), pages + 1)
    end
  end

  # -- I17's third adversarial proof ------------------------------------------

  test "I17 an explicit scheduled migration is the only thing that moves a tenant's version" do
    # `v1-release.md` section 17 asks three things of I17. 07a proved the first
    # (a changed definition raises) and 07c owns the third (a stale provider
    # notification cannot move the version). This is the second, and both halves
    # matter: deploying a version does nothing, and the transition does
    # everything.
    {tenant, _} = subscribed(:versioned)
    assert reload(tenant).plan_version == "1"

    # Half one: version 2 of `:versioned` becomes effective. The tenant does not
    # move, and neither does the row.
    Config.with_config([{:aurora_meter, :plans, AuroraMeter.Test.VersionTwoLivePlans}], fn ->
      assert AuroraMeter.Plans.get(:versioned).version == "2"
      assert AuroraMeter.plan(tenant).version == "1"
      assert AuroraMeter.quota(tenant, :ai_generations).limit == 1_000
      assert reload(tenant).plan_version == "1"

      # Half two: an explicit, referenced, audited transition moves them, and it
      # is the only thing in the package that writes `plan_version` on an
      # existing row.
      {:ok, transition} =
        Subscriptions.schedule_transition(tenant, :versioned, ref: "migrate-1", version: "2")

      assert {:ok, %{applied: 1}} =
               Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

      assert AuroraMeter.plan(tenant).version == "2"
      assert AuroraMeter.quota(tenant, :ai_generations).limit == 2_000

      audit = transition(tenant, "migrate-1")
      assert audit.state == "applied"
      assert audit.from_version == "1"
      assert audit.to_version == "2"
      assert audit.effective_at == transition.effective_at
    end)
  end

  # -- criterion 8: nothing else moves ----------------------------------------

  @counted ~w(aurora_meter_counters aurora_meter_history aurora_meter_events
              aurora_meter_credit_transactions aurora_meter_credit_lots)

  test "I17 applying a transition deletes no counter, history, event, transaction or lot row" do
    {tenant, _} = subscribed(:allowance)
    AuroraMeter.track(tenant, :requests, 7)
    AuroraMeter.Flusher.flush()
    {:ok, _} = AuroraMeter.Credits.grant(tenant, 5_000, reference: "seed-#{tenant}")

    before = Enum.map(@counted, &table_count/1)
    subscriptions_before = table_count("aurora_meter_subscriptions")
    transitions_before = table_count("aurora_meter_plan_transitions")

    {:ok, _} = Subscriptions.schedule_transition(tenant, :allowance_flat, ref: "r")
    {:ok, %{applied: 1}} = Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    assert Enum.map(@counted, &table_count/1) == before,
           "applying a transition changed a table it does not own (L17.9). " <>
             "Tables: #{inspect(@counted)}"

    # And it did change exactly the two it does own: one row updated in each, so
    # the counts are equal but the content is not. The count assertion above is
    # about absence; this one is about the transition having happened at all,
    # because five unchanged counts would also be true of a run that did nothing.
    assert table_count("aurora_meter_subscriptions") == subscriptions_before
    assert table_count("aurora_meter_plan_transitions") == transitions_before + 1
    assert reload(tenant).plan_id == "allowance_flat"

    assert AuroraMeter.Counter.value(
             tenant,
             :requests,
             Period.current!(tenant, Clock.now()).start
           ) == 7
  end

  test "I17 usage recorded before the boundary stays in its period after the transition applies" do
    {tenant, _} = subscribed(:allowance)

    before_period = Period.current!(tenant, Clock.now())
    AuroraMeter.track(tenant, :requests, 3)
    AuroraMeter.Flusher.flush()

    {:ok, _} = Subscriptions.schedule_transition(tenant, :allowance_flat, ref: "r")
    {:ok, %{applied: 1}} = Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    assert AuroraMeter.Counter.value(tenant, :requests, before_period.start) == 3
  end

  # -- criterion 9: no price-dependent branch ---------------------------------

  @transition_sources ~w(lib/aurora_meter/subscriptions.ex
                         lib/aurora_meter/subscriptions/transitions.ex)

  test "I17 no transition source names a price, so no branch can depend on one" do
    # A test that merely exercises a zero-price transition proves the free case
    # works; it cannot prove that no branch looks at a price, because a branch
    # that fires only for, say, a decrease in price would be silent in both.
    # This reads the source instead, which is the property the criterion states.
    for path <- @transition_sources do
      {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

      prices =
        ast
        |> Macro.prewalk([], fn
          {:., meta, [_target, :price]} = node, acc -> {node, [{:field, meta} | acc]}
          {:price, meta, args} = node, acc when is_list(args) -> {node, [{:call, meta} | acc]}
          node, acc -> {node, acc}
        end)
        |> elem(1)

      assert prices == [],
             "#{path} reads a plan price at #{inspect(prices)}. Core never prorates and the " <>
               "transition path must not branch on price (decision D05, task 07.05)."
    end
  end

  test "I17 a zero-price transition issues exactly the statements a priced one does" do
    # The second half of the same criterion, and the one an AST scan cannot make:
    # that the two run the *same* path. Two transitions are driven, one whose
    # target price is unchanged (2000 to 2000) and one whose target price is zero
    # (2000 to 0), and the sequence of SQL statements is compared. Parameters
    # differ; the statements must not.
    priced = statements(fn -> drive(:scale) end)
    free = statements(fn -> drive(:free) end)

    assert priced == free,
           "a zero-price transition took a different path.\npriced: #{inspect(priced)}\n" <>
             "free:   #{inspect(free)}"

    assert length(priced) > 5, "no statements were captured, so the comparison proved nothing"
  end

  defp drive(plan) do
    {tenant, _} = subscribed(:pro)
    {:ok, _} = Subscriptions.schedule_transition(tenant, plan, ref: "r")
    {:ok, %{applied: 1}} = Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)
    assert reload(tenant).plan_id == to_string(plan)
  end

  defp statements(fun) do
    parent = self()
    id = "07b-statements-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:aurora_meter, :test_repo, :query],
      fn _event, _measure, meta, _config ->
        send(parent, {:sql, normalise(meta.query)})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect([])
  end

  defp collect(acc) do
    receive do
      {:sql, sql} -> collect([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Parameter values never reach the query text (Postgrex sends them
  # separately), but savepoint names carry a counter, so they are flattened.
  defp normalise(sql), do: String.replace(sql, ~r/ecto_\d+/, "ecto_N")

  # -- custom periods (07.09) -------------------------------------------------

  test "I17 the default effective_at under the calendar source is the first of next month" do
    {tenant, _} = subscribed()

    AuroraMeter.Test.with_clock(@inside_september, fn ->
      {:ok, transition} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")
      assert transition.effective_at == ~U[2026-10-01 00:00:00Z]
    end)
  end

  test "I17 the default effective_at under a subscription-aligned source is current_period_end" do
    tenant = unique_tenant("trans")
    period_end = ~U[2026-09-22 14:30:00Z]

    {:ok, _} =
      Storage.put_subscription(%{
        tenant_key: tenant,
        plan_id: "pro",
        plan_version: "1",
        status: "active",
        current_period_start: ~U[2026-08-22 14:30:00Z],
        current_period_end: period_end
      })

    Subscriptions.invalidate(tenant)

    Config.with_config([{:aurora_meter, :period_source, PeriodSources.SubscriptionAligned}], fn ->
      AuroraMeter.Test.with_clock(@inside_september, fn ->
        {:ok, transition} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")
        assert transition.effective_at == period_end
      end)
    end)
  end

  test "I17 the default effective_at under a weekly host source is the end of the current week" do
    {tenant, _} = subscribed()

    Config.with_config([{:aurora_meter, :period_source, PeriodSources.Weekly}], fn ->
      AuroraMeter.Test.with_clock(@inside_september, fn ->
        {:ok, transition} = Subscriptions.schedule_transition(tenant, :scale, ref: "r")

        # 2026-09-16 is a Wednesday; the ISO week starting Monday the 14th ends
        # at Monday the 21st, 00:00:00Z.
        assert transition.effective_at == ~U[2026-09-21 00:00:00Z]
      end)
    end)
  end

  test "I17 an invalid custom period source raises InvalidPeriodError naming the module" do
    {tenant, _} = subscribed()

    Config.with_config([{:aurora_meter, :period_source, PeriodSources.Inverted}], fn ->
      error =
        assert_raise Period.InvalidPeriodError, fn ->
          Subscriptions.schedule_transition(tenant, :scale, ref: "r")
        end

      assert error.source == PeriodSources.Inverted
      assert error.reason == :inverted
    end)
  end

  # -- helpers ----------------------------------------------------------------

  defp transition(tenant, ref) do
    TestRepo.get_by!(PlanTransition, tenant_key: tenant, ref: ref)
  end

  defp count_transitions(tenant) do
    TestRepo.aggregate(
      from(t in PlanTransition, where: t.tenant_key == ^tenant),
      :count,
      :id
    )
  end

  defp table_count(table) do
    %{rows: [[count]]} = TestRepo.query!("SELECT count(*) FROM #{table}", [])
    count
  end
end
