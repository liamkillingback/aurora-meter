defmodule AuroraMeter.PlanAttributionTest do
  @moduledoc """
  Build unit 07c, tasks 07.06 and 07.08, G07 bullet 5: which commercial contract
  a recorded fact was sold under, and what happens when there is not one.

  `AuroraMeter.Plans.effective_for/2` answers the question and
  `AuroraMeter.record/4` stamps the answer onto the row, once, at record time
  (L17.12). Nothing downstream recomputes it, which is what stops a plan
  redeploy or a plan change from repricing history (decision D05).

  The resolution rules are exercised against seeded transition rows, because
  they are rules about **data** and seeding is the only way to cover an instant
  between two changes without waiting for one. The end-to-end tests then drive
  the real `schedule_transition/3` and `apply_due_transitions/1` path, so the
  columns 07b writes are the ones this unit reads.
  """
  use AuroraMeter.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Event
  alias AuroraMeter.Plans
  alias AuroraMeter.Schema.PlanTransition
  alias AuroraMeter.Storage
  alias AuroraMeter.Subscriptions
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.RecordingOutbox

  @since ~U[2020-01-01 00:00:00Z]
  @far_future ~U[2030-12-01 00:00:00Z]

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()
    %{tenant: unique_tenant("attr")}
  end

  defp assigned(tenant, plan \\ :pro, since \\ @since) do
    AuroraMeter.Test.subscribe_since!(tenant, plan, since)
    tenant
  end

  # One applied transition, written as data. `effective_at` is what
  # `effective_for/2` reads; `applied_at` is only the audit stamp.
  defp applied!(tenant, from, to, effective_at) do
    {from_plan, from_version} = from
    {to_plan, to_version} = to

    TestRepo.insert!(%PlanTransition{
      tenant_key: tenant,
      ref: "seed-#{System.unique_integer([:positive])}",
      from_plan_id: Atom.to_string(from_plan),
      from_version: from_version,
      to_plan_id: Atom.to_string(to_plan),
      to_version: to_version,
      effective_at: effective_at,
      state: "applied",
      confirm: "local",
      applied_at: DateTime.utc_now()
    })
  end

  defp record(tenant, opts) do
    AuroraMeter.record(
      tenant,
      Keyword.get(opts, :feature, :ai_generations),
      Keyword.get(opts, :quantity, 1),
      Keyword.drop(opts, [:feature, :quantity])
    )
  end

  defp stored(tenant, event_id) do
    TestRepo.one!(
      from(e in AuroraMeter.Schema.Event,
        where: e.tenant_key == ^tenant and e.event_id == ^event_id,
        select: %{
          plan_id: e.plan_id,
          plan_version: e.plan_version,
          attribution: e.attribution
        }
      )
    )
  end

  ## effective_for/2

  test "I17 effective_for answers the current assignment for an instant inside it", ctx do
    assigned(ctx.tenant)

    assert {:ok, {:pro, "1"}} = Plans.effective_for(ctx.tenant, ~U[2026-06-01 00:00:00Z])
  end

  test "I17 effective_for costs no query at all for an instant inside the current assignment",
       ctx do
    assigned(ctx.tenant)
    # Warm the subscription cache, so the only query left to count is the one
    # into the transition history. The claim in the build document is "zero
    # queries in the common case" and this is the assertion that carries it.
    assert %{} = Subscriptions.get(ctx.tenant)

    assert {0, {:ok, {:pro, "1"}}} =
             count_queries(fn -> Plans.effective_for(ctx.tenant, ~U[2026-06-01 00:00:00Z]) end)

    # And the backdated instant is bounded at two indexed single-row reads:
    # one for the latest applied change at or before the instant, and, only
    # when that finds nothing, one for the earliest applied change after it.
    assert {2, {:error, :unresolved}} =
             count_queries(fn -> Plans.effective_for(ctx.tenant, ~U[2019-06-01 00:00:00Z]) end)

    applied!(ctx.tenant, {:free, "1"}, {:pro, "1"}, ~U[2019-01-01 00:00:00Z])

    assert {1, {:ok, {:pro, "1"}}} =
             count_queries(fn -> Plans.effective_for(ctx.tenant, ~U[2019-06-01 00:00:00Z]) end)
  end

  test "I17 effective_for resolves a backdated instant through an applied transition's to side",
       ctx do
    assigned(ctx.tenant, :scale, ~U[2026-06-01 00:00:00Z])
    applied!(ctx.tenant, {:free, "1"}, {:pro, "1"}, ~U[2026-03-01 00:00:00Z])
    applied!(ctx.tenant, {:pro, "1"}, {:scale, "1"}, ~U[2026-06-01 00:00:00Z])

    # Between the two changes: the earlier one's target.
    assert {:ok, {:pro, "1"}} = Plans.effective_for(ctx.tenant, ~U[2026-04-15 00:00:00Z])
    # On the boundary itself the later change has taken effect, because a
    # transition's effective instant belongs to the period it opens.
    assert {:ok, {:scale, "1"}} = Plans.effective_for(ctx.tenant, ~U[2026-06-01 00:00:00Z])
  end

  test "I17 effective_for resolves an instant before the first applied transition from its from side",
       ctx do
    assigned(ctx.tenant, :pro, ~U[2026-03-01 00:00:00Z])
    applied!(ctx.tenant, {:free, "1"}, {:pro, "1"}, ~U[2026-03-01 00:00:00Z])

    # Nothing is applied at or before January, so the answer is what the March
    # change moved the tenant OFF. Recorded history, not a guess: the row says
    # in as many words that the tenant was on `free` version 1 until March.
    assert {:ok, {:free, "1"}} = Plans.effective_for(ctx.tenant, ~U[2026-01-15 00:00:00Z])
  end

  test "I17 effective_for is unresolved for an instant before an assignment with no history",
       ctx do
    assigned(ctx.tenant, :pro, ~U[2026-03-01 00:00:00Z])

    assert {:error, :unresolved} = Plans.effective_for(ctx.tenant, ~U[2026-01-15 00:00:00Z])
  end

  test "I17 effective_for is unresolved for a tenant with no subscription", ctx do
    assert {:error, :unresolved} = Plans.effective_for(ctx.tenant, ~U[2026-06-01 00:00:00Z])
  end

  test "I17 effective_for is unresolved while the row still has no plan_version", ctx do
    # The window between core schema version 10 and the first `register!/0`.
    # `schedule_transition/3` refuses one of these rows outright; attribution
    # refuses to name a contract for it, for the same reason.
    {:ok, _row} =
      Storage.put_subscription(%{
        tenant_key: ctx.tenant,
        plan_id: "pro",
        status: "active",
        plan_effective_at: @since
      })

    Subscriptions.invalidate(ctx.tenant)

    assert %{plan_version: nil} = Subscriptions.get(ctx.tenant)
    assert {:error, :unresolved} = Plans.effective_for(ctx.tenant, ~U[2026-06-01 00:00:00Z])
  end

  test "I17 effective_for ignores a cancelled or pending transition and reads only applied ones",
       ctx do
    assigned(ctx.tenant, :pro, ~U[2026-03-01 00:00:00Z])

    TestRepo.insert!(%PlanTransition{
      tenant_key: ctx.tenant,
      ref: "cancelled",
      from_plan_id: "free",
      from_version: "1",
      to_plan_id: "scale",
      to_version: "1",
      effective_at: ~U[2026-01-01 00:00:00Z],
      state: "cancelled",
      confirm: "local"
    })

    # A change that never happened attributes nothing, in either direction.
    assert {:error, :unresolved} = Plans.effective_for(ctx.tenant, ~U[2026-02-01 00:00:00Z])
  end

  ## The stamp on a recorded event

  test "I17 record stamps plan_id and plan_version from the plan effective at occurred_at", ctx do
    assigned(ctx.tenant)

    assert {:ok, event, :inserted} =
             record(ctx.tenant, id: "now", occurred_at: DateTime.utc_now())

    assert event.plan_id == "pro"
    assert event.plan_version == "1"
    assert event.attribution == :resolved

    assert stored(ctx.tenant, "now") == %{
             plan_id: "pro",
             plan_version: "1",
             attribution: "resolved"
           }
  end

  test "I17 record of a backdated event resolves the version through applied transition history",
       ctx do
    assigned(ctx.tenant, :scale, ~U[2026-06-01 00:00:00Z])
    applied!(ctx.tenant, {:pro, "1"}, {:scale, "1"}, ~U[2026-06-01 00:00:00Z])

    AuroraMeter.Test.with_clock(~U[2026-06-10 12:00:00.000000Z], fn ->
      assert {:ok, event, :inserted} =
               record(ctx.tenant, id: "late", occurred_at: ~U[2026-05-20 09:00:00.000000Z])

      assert event.plan_id == "pro"
      assert event.plan_version == "1"
      assert event.attribution == :resolved
    end)
  end

  test "I17 record of an event predating recorded history stores attribution unresolved and quarantines its outbox item",
       ctx do
    # The tenant exists and is paying; the fact is dated before the contract
    # started and nothing recorded covers it. There is no plan to name, and the
    # one thing that must not happen is today's plan being written onto it.
    assigned(ctx.tenant, :pro, DateTime.utc_now())

    TestConfig.with_config(
      [
        {:aurora_meter, :events_outbox, RecordingOutbox},
        {:aurora_meter, :feature_sources, %{ai_generations: :events}}
      ],
      fn ->
        assert {:ok, event, :inserted} =
                 record(ctx.tenant,
                   id: "before-history",
                   occurred_at: DateTime.add(DateTime.utc_now(), -3600, :second)
                 )

        assert event.attribution == :plan_unresolved
        assert event.plan_id == nil
        assert event.plan_version == nil

        assert stored(ctx.tenant, "before-history") == %{
                 plan_id: nil,
                 plan_version: nil,
                 attribution: "plan_unresolved"
               }

        # The export intent is staged, named and not delivered. Core says why;
        # what an implementation does with the reason is the implementation's
        # (Aurora Meter Pro quarantines it as `plan_unresolved`).
        assert [%{eligibility: {:ineligible, :plan_unresolved}}] = RecordingOutbox.items()
      end
    )
  end

  test "I17 record for a tenant with no subscription stores attribution unresolved", ctx do
    TestConfig.with_config(
      [
        {:aurora_meter, :events_outbox, RecordingOutbox},
        {:aurora_meter, :feature_sources, %{ai_generations: :events}}
      ],
      fn ->
        assert {:ok, event, :inserted} =
                 record(ctx.tenant, id: "no-sub", occurred_at: DateTime.utc_now())

        assert event.attribution == :plan_unresolved
        assert event.plan_id == nil
        assert [%{eligibility: {:ineligible, :plan_unresolved}}] = RecordingOutbox.items()
      end
    )
  end

  test "I17 an unresolved period is not asked for a plan at all", ctx do
    # Order matters here and only here: when the period source cannot place the
    # instant, the period on the row is an approximation, and resolving a
    # commercial contract against an approximated instant would be worse than
    # not resolving one. `:unresolved` therefore wins over `:plan_unresolved`.
    assigned(ctx.tenant)

    TestConfig.with_config(
      [
        {:aurora_meter, :events_outbox, RecordingOutbox},
        {:aurora_meter, :period_source, AuroraMeter.Test.PeriodSources.FutureWindow},
        {:aurora_meter, :feature_sources, %{ai_generations: :events}}
      ],
      fn ->
        assert {:ok, event, :inserted} =
                 record(ctx.tenant, id: "no-period", occurred_at: DateTime.utc_now())

        assert event.attribution == :unresolved
        assert event.plan_id == nil
        assert [%{eligibility: {:ineligible, :attribution_unresolved}}] = RecordingOutbox.items()
      end
    )
  end

  test "I09 a correction copies the original's plan_id, plan_version and attribution", ctx do
    assigned(ctx.tenant)

    assert {:ok, original, :inserted} =
             record(ctx.tenant, id: "base", quantity: 10, occurred_at: DateTime.utc_now())

    # The plan changes between the fact and its correction. The correction is
    # still the reversal of THAT fact, so it is priced as that fact was.
    AuroraMeter.Test.subscribe_since!(ctx.tenant, :scale, DateTime.utc_now())

    assert {:ok, correction, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

    assert correction.plan_id == original.plan_id
    assert correction.plan_version == original.plan_version
    assert correction.attribution == original.attribution
    assert correction.plan_id == "pro"
  end

  test "I06 a retry of one event_id across a plan change is a duplicate and keeps the first stamp",
       ctx do
    # Finding X302. The 07c build document proposed putting the attribution
    # stamp inside `payload_hash`, which would make this call a CONFLICT: the
    # same caller, the same fact, the same id, and a derived column that moved
    # underneath it. The hash separates "a retry of the same fact" from "a
    # different fact reusing the identity", and attribution is not part of the
    # fact the caller sent. It is excluded, and this is the assertion that says
    # so.
    assigned(ctx.tenant)
    at = DateTime.utc_now()

    assert {:ok, first, :inserted} = record(ctx.tenant, id: "retry", quantity: 5, occurred_at: at)
    assert first.plan_id == "pro"

    AuroraMeter.Test.subscribe_since!(ctx.tenant, :scale, @since)

    assert {:ok, second, :duplicate} =
             record(ctx.tenant, id: "retry", quantity: 5, occurred_at: at)

    assert second.plan_id == "pro"
    assert second.plan_version == "1"
    assert stored(ctx.tenant, "retry").plan_id == "pro"
  end

  test "I17 usage recorded before a transition keeps the old version after the transition applies",
       ctx do
    # G07 bullet 5, end to end and through the real scheduler, so the columns
    # build unit 07b writes are the ones read back.
    assigned(ctx.tenant, :pro, @since)
    now = DateTime.utc_now()
    boundary = DateTime.add(now, 2, :second)

    {:ok, _transition} =
      Subscriptions.schedule_transition(ctx.tenant, :scale,
        ref: "upgrade",
        effective_at: boundary
      )

    assert {:ok, before_event, :inserted} =
             record(ctx.tenant, id: "before", occurred_at: DateTime.add(now, -600, :second))

    assert {:ok, %{applied: 1}} =
             Subscriptions.apply_due_transitions(tenant: ctx.tenant, now: @far_future)

    Subscriptions.invalidate(ctx.tenant)
    assert Subscriptions.get(ctx.tenant).plan_id == "scale"

    # The fact recorded before the change did not move, and re-reading it does
    # not resolve it again: the stamp is on the row.
    assert before_event.plan_id == "pro"

    assert stored(ctx.tenant, "before") == %{
             plan_id: "pro",
             plan_version: "1",
             attribution: "resolved"
           }

    # A fact dated after the boundary is the new contract's. `occurred_at` is
    # inside the future tolerance, which is what lets this run without waiting
    # for the boundary to pass.
    assert {:ok, after_event, :inserted} =
             record(ctx.tenant, id: "after", occurred_at: DateTime.add(now, 30, :second))

    assert after_event.plan_id == "scale"
    assert after_event.plan_version == "1"

    # And the backdated one resolves the same way through history now that the
    # assignment has moved on: the transition's `from` side is `pro` version 1.
    assert {:ok, {:pro, "1"}} =
             Plans.effective_for(ctx.tenant, DateTime.add(now, -600, :second))
  end

  test "I17 a plan definition redeployed under a tenant does not change a recorded stamp", ctx do
    assigned(ctx.tenant, :versioned, @since)

    assert {:ok, event, :inserted} =
             record(ctx.tenant, id: "v1", occurred_at: DateTime.utc_now())

    assert %Event{plan_id: "versioned", plan_version: "1"} = event

    # Version 2 of the same plan becomes effective. Nothing about the recorded
    # row moves, and nothing about the tenant's assignment moves either (D05).
    TestConfig.with_config(
      [{:aurora_meter, :plans, AuroraMeter.Test.VersionTwoLivePlans}],
      fn ->
        assert Plans.get(:versioned).version == "2"
        assert stored(ctx.tenant, "v1").plan_version == "1"
        assert {:ok, {:versioned, "1"}} = Plans.effective_for(ctx.tenant, DateTime.utc_now())
      end
    )
  end

  # Counts the SQL statements one function issues, through the repo's telemetry
  # event. Filtered to this test's own process, so a concurrent case cannot
  # inflate the count (X214: count the branch, do not hope for it).
  defp count_queries(fun) do
    owner = self()
    handler = "count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:aurora_meter, :test_repo, :query],
      fn _event, _measurements, _metadata, _config -> send(owner, {:query, handler}) end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {drain(handler, 0), result}
  end

  defp drain(handler, count) do
    receive do
      {:query, ^handler} -> drain(handler, count + 1)
    after
      0 -> count
    end
  end
end
