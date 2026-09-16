defmodule AuroraMeter.PlanTransitionsConcurrencyTest do
  @moduledoc """
  Build unit 07b, invariant I16: twelve independent connections, two nodes, a
  cancel racing an apply, a provider sync racing an apply, and three kills.

  Not `AuroraMeter.DataCase`. The sandbox wraps a test in one transaction on one
  connection, which serialises the very contention a row lock and a conditional
  update exist to survive: every task here takes its own non-sandbox connection
  through `AuroraMeter.Test.Connections` and every assertion is made on what the
  database holds afterwards.

  **The contention is forced, not hoped for** (`open-findings.md` X182, X186,
  X187). The twelve-way apply queues behind a thirteenth process that is
  holding the subscription row's `FOR UPDATE` when they start, and the number of
  processes actually waiting on that lock is read out of `pg_stat_activity` and
  asserted. `pg_locks` filtered by database does not show a row-lock waiter at
  all, which is why the waiter count is taken from `pg_stat_activity`'s
  `wait_event_type = 'Lock'` instead.

  **Every contended branch is counted on an ordinary run** (X214). Eleven skips,
  eleven idempotent schedules and one winner per race are assertions, not a
  report behind an environment variable.
  """
  use ExUnit.Case, async: false

  # `mix v1.faults` (an alias in mix.exs) runs every module tagged :fault with a
  # fixed seed, and CI runs it as its own job. The tag is NOT excluded in
  # test/test_helper.exs, so this module also runs inside the ordinary `mix test`
  # and the dedicated job is a second, seeded run rather than the only one.
  @moduletag :fault

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Config
  alias AuroraMeter.Schema.PlanTransition
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Subscriptions
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.FaultRepo
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @tasks 12
  @far_future ~U[2030-12-01 00:00:00Z]
  @telemetry [:aurora_meter, :plans, :transition]

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    Connections.register_prefix("plantrans")
    on_exit(fn -> Connections.cleanup!("plantrans") end)
    :ok
  end

  # A transition whose boundary has arrived. The scheduler refuses a past
  # `effective_at` (it is a scheduled change, not a retroactive one), so a test
  # that needs a due transition without an injected `now:` moves the boundary
  # in the database, which is what the passage of time would have done.
  defp make_due!(tenant) do
    past = ~N[2026-01-01 00:00:00]

    TestRepo.query!(
      "UPDATE aurora_meter_plan_transitions SET effective_at = $2 WHERE tenant_key = $1",
      [tenant, past]
    )

    TestRepo.query!(
      "UPDATE aurora_meter_subscriptions SET scheduled_effective_at = $2 WHERE tenant_key = $1",
      [tenant, past]
    )

    Subscriptions.invalidate(tenant)
  end

  defp tenant! do
    tenant = AuroraMeter.Test.unique_tenant("plantrans")
    {:ok, _} = AuroraMeter.subscribe(tenant, :pro)
    Subscriptions.invalidate(tenant)
    tenant
  end

  defp scheduled!(tenant, to_plan \\ :scale, opts \\ []) do
    {:ok, transition} = Subscriptions.schedule_transition(tenant, to_plan, [ref: "r"] ++ opts)
    Subscriptions.invalidate(tenant)
    transition
  end

  defp transitions(tenant) do
    TestRepo.all(from(t in PlanTransition, where: t.tenant_key == ^tenant))
  end

  defp row(tenant), do: TestRepo.get_by!(Subscription, tenant_key: tenant)

  # -- criterion 2: twelve schedules of one reference -------------------------

  test "I16 twelve independent connections scheduling one ref produce one transition row" do
    tenant = tenant!()
    results = collecting(fn -> race(fn -> schedule(tenant) end) end)

    assert length(results.values) == @tasks
    assert Enum.all?(results.values, &match?({:ok, %PlanTransition{}}, &1))

    ids = results.values |> Enum.map(fn {:ok, t} -> t.id end) |> Enum.uniq()
    assert length(ids) == 1, "twelve callers saw #{length(ids)} different transitions"

    assert length(transitions(tenant)) == 1
    assert row(tenant).transition_ref == "r"
    assert row(tenant).transition_state == "pending"

    # The contended branch, counted. Eleven callers found the reference already
    # written and returned it unchanged; one wrote it. A zero here would mean
    # the tasks were not racing at all, and the row count above cannot tell the
    # two apart.
    assert results.counts[:idempotent] == @tasks - 1
    assert results.counts[:scheduled] == 1

    IO.puts("\n[07b] twelve schedules of one ref: #{inspect(results.counts)} rows=1")
  end

  # -- criterion 3: twelve appliers of one due transition ---------------------

  test "I16 twelve independent connections applying one due transition apply it once" do
    tenant = tenant!()
    scheduled!(tenant)

    {results, waiters} =
      behind_the_row_lock(tenant, fn ->
        race(fn -> Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future) end)
      end)

    assert length(results) == @tasks

    applied = Enum.count(results, &match?({:ok, %{applied: 1}}, &1))
    skipped = Enum.count(results, &match?({:ok, %{applied: 0, skipped: 1}}, &1))

    assert applied == 1
    assert skipped == @tasks - 1

    assert [%PlanTransition{state: "applied"}] = transitions(tenant)
    assert row(tenant).plan_id == "scale"
    assert row(tenant).transition_state == "applied"

    # And they really did queue on the subscription row rather than arriving one
    # after another: the holder was still inside its transaction when this many
    # of them were blocked on its lock.
    assert waiters == @tasks,
           "only #{waiters} of #{@tasks} appliers were waiting on the subscription row lock, " <>
             "so the skips above may be sequential rather than contended"

    IO.puts(
      "\n[07b] twelve appliers of one due transition: applied=#{applied} skipped=#{skipped} " <>
        "row_lock_waiters=#{waiters}"
    )
  end

  # -- cancel, provider sync and two nodes ------------------------------------

  @rounds 10

  test "I16 a cancel racing an apply yields exactly one terminal state" do
    outcomes =
      for _round <- 1..@rounds do
        tenant = tenant!()
        scheduled!(tenant)

        [apply_result, cancel_result] =
          pair(
            fn -> Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future) end,
            fn -> Subscriptions.cancel_transition(tenant, "r") end
          )

        [transition] = transitions(tenant)
        assert transition.state in ["applied", "cancelled"]

        assert row(tenant).plan_id == expected_plan(transition.state)
        assert row(tenant).transition_state == transition.state

        winners(apply_result, cancel_result, transition.state)
      end

    # Exactly one winner in every round: whichever ran second failed its own
    # predicate and said so rather than overwriting the first.
    assert Enum.sum(outcomes) == @rounds
  end

  defp expected_plan("applied"), do: "scale"
  defp expected_plan("cancelled"), do: "pro"

  defp winners(apply_result, cancel_result, state) do
    apply_won =
      case {apply_result, state} do
        {{:ok, %{applied: 1}}, "applied"} -> 1
        {{:ok, %{applied: 0, skipped: 1}}, "cancelled"} -> 0
      end

    cancel_won =
      case {cancel_result, state} do
        {{:ok, %PlanTransition{state: "cancelled"}}, "cancelled"} -> 1
        {{:error, {:conflict, %{state: "applied"}}}, "applied"} -> 0
      end

    apply_won + cancel_won
  end

  test "I16 a provider sync racing an apply yields one terminal state and one plan" do
    for _round <- 1..@rounds do
      tenant = tenant!()
      scheduled!(tenant)

      pair(
        fn -> Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future) end,
        fn ->
          Storage.put_subscription(%{
            tenant_key: tenant,
            plan_id: "payg",
            plan_version: "1",
            status: "active"
          })
        end
      )

      [transition] = transitions(tenant)
      assert transition.state in ["applied", "cancelled"]

      # Whichever won, the subscription names one plan and the audit row agrees
      # with it. The apply winning means the sync arrived after and wrote its own
      # plan over a settled transition, which is the provider being right about
      # now; the sync winning means the transition was cancelled and never
      # applied.
      settled = row(tenant)
      assert settled.transition_state == transition.state

      if transition.state == "cancelled" do
        assert transition.detail["reason"] == "provider_override"
        assert settled.plan_id == "payg"
      end
    end
  end

  # Guarded, because the headless CI leg compiles every test file with Oban
  # absent and `%Oban.Job{}` is a struct that does not exist there. The rest of
  # this module needs a database and not Oban, so only this test is behind the
  # check rather than the whole file.
  if Code.ensure_loaded?(Oban) do
    alias AuroraMeter.Oban.PlanTransitions

    test "I16 two Oban jobs from two nodes apply one transition" do
      tenant = tenant!()
      scheduled!(tenant)

      # No injected `now:` here on purpose. The worker maps job arguments onto
      # the operation's options and takes the database's clock for "now", which
      # is the path a real crontab tick follows, so the boundary is moved
      # instead.
      make_due!(tenant)

      results =
        Connections.run(2, fn _i ->
          PlanTransitions.perform(%Oban.Job{args: %{"tenant" => tenant}})
        end)

      assert length(results) == 2
      assert Enum.all?(results, &match?({:ok, %{}}, &1))
      assert Enum.count(results, &match?({:ok, %{applied: 1}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, %{applied: 0, skipped: 1}}, &1)) == 1

      assert [%PlanTransition{state: "applied"}] = transitions(tenant)
      assert row(tenant).plan_id == "scale"
    end
  end

  # -- kills ------------------------------------------------------------------

  test "I16 the applier killed before commit leaves the transition pending" do
    tenant = tenant!()
    scheduled!(tenant)

    TestConfig.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      {:killed, _pid} =
        Kill.run(
          fn -> with_connection(fn -> apply_now(tenant) end) end,
          at: :before_commit,
          when: &(&1[:statement] == :subscription_upsert and &1[:repo_fun] == :update_all)
        )
    end)

    Faults.assert_fired!(:before_commit)

    assert Kill.assert_db!(fn -> row(tenant).plan_id end) == "pro"
    assert Kill.assert_db!(fn -> row(tenant).transition_state end) == "pending"
    assert Kill.assert_db!(fn -> hd(transitions(tenant)).state end) == "pending"

    # And the next run applies it, which is the whole reason a crash is allowed
    # to leave it pending rather than failed.
    assert {:ok, %{applied: 1}} = apply_now(tenant)
  end

  test "I16 the applier killed after commit and before cache invalidation converges" do
    ttl = Config.subscription_cache_ttl()
    assert ttl > 0, "the cache is disabled, so this test would prove nothing"

    tenant = tenant!()
    scheduled!(tenant)

    # Warm this node's cache with the OLD plan, and start the clock there: the
    # entry expires `ttl` after the read that created it.
    assert Subscriptions.get(tenant).plan_id == "pro"
    warmed_at = System.monotonic_time(:millisecond)

    TestConfig.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      {:killed, _pid} =
        Kill.run(fn -> with_connection(fn -> apply_now(tenant) end) end,
          at: :after_commit_before_ack
        )
    end)

    Faults.assert_fired!(:after_commit_before_ack)
    killed_at = System.monotonic_time(:millisecond)

    # The database is already correct. Nothing is lost by the kill.
    assert Storage.get_subscription(tenant).plan_id == "scale"
    assert hd(transitions(tenant)).state == "applied"

    # And this node is serving the old plan, because the invalidation never ran.
    assert Subscriptions.get(tenant).plan_id == "pro"

    converged_at = converge(tenant, "scale", warmed_at + 4 * ttl)
    window = converged_at - warmed_at

    IO.puts(
      "\n[07b] cache staleness after a kill: ttl=#{ttl}ms " <>
        "window_from_warm=#{window}ms window_from_kill=#{converged_at - killed_at}ms"
    )

    assert window > 0
    assert window <= ttl + 1_000, "the stale window was #{window}ms against a #{ttl}ms TTL"
  end

  test "I16 the applier killed mid-batch leaves the applied tenants applied and the rest pending" do
    tenants =
      for i <- 1..4 do
        tenant = "plantrans_batch#{i}_#{System.unique_integer([:positive])}"
        Connections.register_prefix("plantrans")
        {:ok, _} = AuroraMeter.subscribe(tenant, :pro)

        {:ok, _} =
          Subscriptions.schedule_transition(tenant, :scale,
            ref: "r",
            effective_at: DateTime.add(~U[2027-01-01 00:00:00Z], i, :day)
          )

        tenant
      end

    counter = :counters.new(1, [])

    TestConfig.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      {:killed, _pid} =
        Kill.run(
          fn ->
            with_connection(fn ->
              Subscriptions.apply_due_transitions(limit: 10, now: @far_future)
            end)
          end,
          at: :after_commit_before_ack,
          when: fn _context ->
            :counters.add(counter, 1, 1)
            :counters.get(counter, 1) == 2
          end
        )
    end)

    Faults.assert_fired!(:after_commit_before_ack)

    states =
      Kill.assert_db!(fn ->
        Enum.map(tenants, fn tenant -> {row(tenant).plan_id, transition_state(tenant)} end)
      end)

    applied = Enum.count(states, &match?({"scale", "applied"}, &1))
    pending = Enum.count(states, &match?({"pro", "pending"}, &1))

    assert applied == 2, "expected the first two tenants applied, got #{inspect(states)}"
    assert applied + pending == length(tenants)

    # The next run finishes exactly the complement, and nothing is applied twice.
    assert {:ok, %{applied: 2, skipped: 0}} =
             Subscriptions.apply_due_transitions(limit: 10, now: @far_future)
  end

  defp transition_state(tenant) do
    TestRepo.get_by!(PlanTransition, tenant_key: tenant, ref: "r").state
  end

  # -- plumbing ---------------------------------------------------------------

  defp apply_now(tenant) do
    Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)
  end

  defp with_connection(fun) do
    own = Connections.checkout!()

    try do
      fun.()
    after
      if own, do: Sandbox.checkin(Connections.repo())
    end
  end

  defp schedule(tenant) do
    Subscriptions.schedule_transition(tenant, :scale, ref: "r")
  end

  # Every task waits for the last of them before it acts, so the calls are
  # issued together rather than in the order the scheduler happened to start
  # them. A barrier that is never released is a named failure rather than a
  # hang.
  defp race(fun) do
    gate = :counters.new(1, [])

    Connections.run(@tasks, fn _i ->
      :counters.add(gate, 1, 1)
      await_gate(gate, @tasks, System.monotonic_time(:millisecond) + 5_000)
      fun.()
    end)
  end

  defp pair(left, right) do
    gate = :counters.new(1, [])

    Connections.run(2, fn i ->
      :counters.add(gate, 1, 1)
      await_gate(gate, 2, System.monotonic_time(:millisecond) + 5_000)
      if i == 1, do: left.(), else: right.()
    end)
  end

  defp await_gate(gate, n, deadline) do
    cond do
      :counters.get(gate, 1) >= n ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "the rendezvous never released: #{:counters.get(gate, 1)} of #{n} arrived"

      true ->
        :erlang.yield()
        await_gate(gate, n, deadline)
    end
  end

  # Holds the tenant's subscription row under `FOR UPDATE` in its own
  # transaction, runs `fun` while every caller inside it is blocked on that
  # lock, records how many of them the database says are waiting, and only then
  # commits.
  defp behind_the_row_lock(tenant, fun) do
    parent = self()

    holder =
      spawn_link(fn ->
        :ok = Sandbox.checkout(TestRepo, sandbox: false)

        TestRepo.transaction(fn ->
          TestRepo.one!(
            from(s in Subscription, where: s.tenant_key == ^tenant, lock: "FOR UPDATE")
          )

          send(parent, {:holding, self()})

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end)

        Sandbox.checkin(TestRepo)
      end)

    assert_receive {:holding, ^holder}, 5_000

    task = Task.async(fun)
    waiters = await_waiters(@tasks, System.monotonic_time(:millisecond) + 10_000, 0)
    send(holder, :release)

    {Task.await(task, 30_000), waiters}
  end

  # `pg_locks` filtered by `database` does not list a process waiting for a row
  # lock, so the count comes from `pg_stat_activity`, where such a process
  # reports `wait_event_type = 'Lock'`.
  @waiting_sql """
  SELECT count(*) FROM pg_stat_activity
   WHERE wait_event_type = 'Lock' AND state = 'active'
  """

  defp await_waiters(target, deadline, best) do
    %{rows: [[count]]} = TestRepo.query!(@waiting_sql, [])
    best = max(best, count)

    cond do
      best >= target -> best
      System.monotonic_time(:millisecond) > deadline -> best
      true -> await_waiters(target, deadline, best)
    end
  end

  defp converge(tenant, plan, deadline) do
    if Subscriptions.get(tenant).plan_id == plan do
      System.monotonic_time(:millisecond)
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("the cache never converged on #{plan}")
      else
        :erlang.yield()
        converge(tenant, plan, deadline)
      end
    end
  end

  # One telemetry handler for the whole race, so the branch each of the twelve
  # took is counted rather than inferred from the rows they left behind.
  defp collecting(fun) do
    parent = self()
    id = "07b-race-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      @telemetry,
      fn _event, _measure, meta, _config -> send(parent, {:transition, meta.result}) end,
      nil
    )

    values =
      try do
        fun.()
      after
        :telemetry.detach(id)
      end

    %{values: values, counts: drain(%{})}
  end

  defp drain(counts) do
    receive do
      {:transition, result} -> drain(Map.update(counts, result, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end
end
