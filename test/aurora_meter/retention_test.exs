defmodule AuroraMeter.RetentionTest do
  @moduledoc """
  Build unit 05d. Most of this file is about what must **not** be deleted.

  Retention is the only feature in this package whose failure mode is the
  permanent loss of data, so the shape of the suite is deliberately lopsided:
  one test that the two disposable tables are actually pruned, and a dozen that
  everything else survives a prune that was told to delete everything older than
  this instant.

  The Flusher is suspended for every test here. It writes a heartbeat row of its
  own on an idle tick, and in shared sandbox mode that row lands inside the
  test's transaction, which would make an assertion about which nodes are
  reporting depend on a 60 second timer.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Retention
  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Schema.FlushReceipt
  alias AuroraMeter.Schema.History
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage.Ecto, as: EctoStorage

  doctest AuroraMeter.Retention, import: true

  @two_years_ago ~U[2024-09-15 00:00:00.000000Z]
  @two_years_ago_sec ~U[2024-09-15 00:00:00Z]
  @sixty_days 60 * 86_400
  @protected_schemas [
    Counter,
    CreditBalance,
    CreditTransaction,
    Event,
    EventTotal,
    History,
    Subscription
  ]

  setup do
    # See the moduledoc. `:sys.suspend/1` stops the Flusher processing its own
    # timer messages; they queue and are handled after `:sys.resume/1`.
    :sys.suspend(AuroraMeter.Flusher)
    on_exit(fn -> :sys.resume(AuroraMeter.Flusher) end)

    clear_heartbeats!()
    TestRepo.delete_all(FlushReceipt)

    :ok
  end

  # ---------------------------------------------------------------------------
  # The protected list: the most important tests in this unit
  # ---------------------------------------------------------------------------

  test "prune/1 deletes nothing from any protected table" do
    tenant = unique_tenant("retain")
    before = populate!(tenant)

    # Something the prune IS allowed to delete, and a fleet that permits it, so
    # this cannot pass by the prune having refused to run at all (the shape
    # open-findings.md X182 and X125 describe).
    receipts!(3, @sixty_days)
    idle_heartbeat!("node_a")

    # Told to delete everything older than right now, across the whole allow
    # list, with no narrowing at all.
    assert {:ok, report} = Retention.prune(older_than: DateTime.utc_now())
    assert report.flush_receipts == 3, "the prune deleted nothing at all, so it proves nothing"

    for {schema, count} <- before do
      assert TestRepo.aggregate(schema, :count) == count,
             "#{schema.__schema__(:source)} lost rows to a prune"
    end
  end

  test "prune/1 deletes no live checkpoint row, only finished replay rows" do
    Checkpoints.put("credit_expiry:global", %{"id" => "x"}, %{}, "idle")
    Checkpoints.put("events_projection", %{"active_generation" => 0}, %{}, "active")
    Checkpoints.put("events_backfill", %{"seq" => 12}, %{}, "running")
    Checkpoints.put("schema:core", %{}, %{}, "applied")
    Checkpoints.put("events_replay:9", %{"seq" => 4}, %{}, "running")
    age!("events_replay:9", @two_years_ago)

    # A finished replay row that IS disposable, so a prune that deleted nothing
    # because it refused to run would fail this test rather than pass it.
    Checkpoints.put("events_replay:10", %{}, %{}, "activated")
    age!("events_replay:10", @two_years_ago)

    assert {:ok, report} = Retention.prune(older_than: DateTime.utc_now())
    assert report.replay_checkpoints == 1
    refute Checkpoints.get("events_replay:10")

    for name <- ~w(credit_expiry:global events_projection events_backfill schema:core
                   events_replay:9) do
      assert Checkpoints.get(name), "#{name} was deleted by a prune"
    end
  end

  test "prune/1 deletes the active generation's replay row at no age" do
    # The finished state alone is not enough: the row belonging to the
    # generation currently serving reads is the provenance of the live
    # projection.
    Checkpoints.put(
      "events_projection",
      %{"active_generation" => 7, "previous_generation" => 6},
      %{},
      "active"
    )

    for generation <- [6, 7, 8] do
      Checkpoints.put("events_replay:#{generation}", %{}, %{}, "activated")
      age!("events_replay:#{generation}", @two_years_ago)
    end

    assert {:ok, report} = Retention.prune(older_than: DateTime.utc_now())

    assert report.replay_checkpoints == 1
    assert Checkpoints.get("events_replay:7"), "the active generation's row was deleted"
    assert Checkpoints.get("events_replay:6"), "the previous generation's row was deleted"
    refute Checkpoints.get("events_replay:8")
  end

  test "prune/1 raises ArgumentError for a table outside the allow list" do
    for named <- [:aurora_meter_credit_transactions, :events, :credit_lots, "flush_receipts"] do
      assert_raise ArgumentError, ~r/is not a table AuroraMeter\.Retention may delete from/, fn ->
        Retention.prune(only: [named])
      end

      assert_raise ArgumentError, fn -> Retention.plan(only: [named]) end
    end
  end

  test "the allow list and the protected list together name every table the package creates" do
    created = tables_the_migrations_create()
    allowed = Enum.map(Retention.__allow__(), & &1.table)
    classified = MapSet.new(allowed ++ Retention.protected())

    assert created != [], "the migration scan found no tables, so this test proves nothing"

    unclassified = Enum.reject(created, &MapSet.member?(classified, &1))

    assert unclassified == [], """
    These tables are created by AuroraMeter.Migration and appear in neither the
    retention allow list nor the protected list:

      #{Enum.join(unclassified, "\n  ")}

    A table nobody classified is a table that grows for ever, or worse, one a
    later prune reaches. Add it to @protected in lib/aurora_meter/retention.ex,
    or to @allow with an age predicate AND a state predicate.
    """

    # The other direction, which is the one a rename breaks (open-findings.md
    # X206): every name in either list is a table something actually creates.
    invented = Enum.reject(allowed ++ Retention.protected(), &(&1 in created))

    assert invented == [], """
    These names are classified by AuroraMeter.Retention and are created by no
    migration in this package: #{inspect(invented)}
    """
  end

  test "plan/1 and prune/1 are generated from one predicate" do
    # L05d-2, asserted structurally as well as behaviourally. A dry run whose
    # predicate has drifted from the delete's is worse than no dry run: it tells
    # an operator a number that is not what will happen.
    for entry <- Retention.__allow__() do
      {count_sql, count_params} = Retention.count_sql(entry, nil)
      {delete_sql, delete_params} = Retention.delete_sql(entry, nil)

      assert String.contains?(count_sql, entry.predicate),
             "the count statement for #{entry.key} does not carry the shared predicate"

      assert String.contains?(delete_sql, entry.predicate),
             "the delete statement for #{entry.key} does not carry the shared predicate"

      assert count_params == delete_params
      assert String.contains?(count_sql, "count(*)")
      assert String.contains?(delete_sql, "DELETE FROM #{entry.table}")
      refute String.contains?(count_sql, "DELETE")
    end
  end

  # ---------------------------------------------------------------------------
  # The dry run
  # ---------------------------------------------------------------------------

  test "plan/1 writes nothing" do
    tenant = unique_tenant("retain")
    before = populate!(tenant)
    receipts = receipts!(3, @sixty_days)
    idle_heartbeat!("node_a")

    assert {:ok, plan} = Retention.plan([])
    assert plan.flush_receipts == 3

    for {schema, count} <- before do
      assert TestRepo.aggregate(schema, :count) == count
    end

    assert TestRepo.aggregate(FlushReceipt, :count) == length(receipts)
    assert length(all_checkpoint_names()) == 1
  end

  test "plan/1 returns exactly the counts prune/1 then deletes" do
    # A mix of eligible and ineligible rows in both tables, so a predicate that
    # counted everything or nothing would show up.
    receipts!(7, @sixty_days)
    receipts!(4, 3600)
    idle_heartbeat!("node_a")

    Checkpoints.put("events_projection", %{"active_generation" => 0}, %{}, "active")

    for generation <- [11, 12] do
      Checkpoints.put("events_replay:#{generation}", %{}, %{}, "activated")
      age!("events_replay:#{generation}", @two_years_ago)
    end

    Checkpoints.put("events_replay:13", %{}, %{}, "running")
    age!("events_replay:13", @two_years_ago)

    assert {:ok, plan} = Retention.plan([])
    assert plan == %{flush_receipts: 7, replay_checkpoints: 2}

    assert {:ok, pruned} = Retention.prune([])
    assert pruned == plan

    assert {:ok, %{flush_receipts: 0, replay_checkpoints: 0}} = Retention.plan([])
    assert TestRepo.aggregate(FlushReceipt, :count) == 4
  end

  test "plan/1 reports the same blocked reasons prune/1 would" do
    receipts!(2, @sixty_days)
    pending_heartbeat!("node_a", @sixty_days + 86_400)

    assert {:blocked, plan, plan_reasons} = Retention.plan([])
    assert {:blocked, pruned, prune_reasons} = Retention.prune([])

    assert plan == %{flush_receipts: 0, replay_checkpoints: 0}
    assert pruned == plan
    assert Enum.map(plan_reasons, & &1.reason) == Enum.map(prune_reasons, & &1.reason)
    assert Enum.map(plan_reasons, & &1.table) == [:flush_receipts]
  end

  test "prune/1 honours :only and never widens it" do
    receipts!(3, @sixty_days)
    idle_heartbeat!("node_a")

    assert {:ok, report} = Retention.prune(only: [:replay_checkpoints])
    assert Map.keys(report) == [:replay_checkpoints]
    assert TestRepo.aggregate(FlushReceipt, :count) == 3
  end

  test "prune/1 stops at :max_items and the next run continues" do
    receipts!(10, @sixty_days)
    idle_heartbeat!("node_a")

    # A run that fills its budget with rows still eligible says so, rather than
    # returning an `{:ok, _}` that looks complete.
    assert {:blocked, report, [%{table: :flush_receipts, reason: :budget_exhausted} = reason]} =
             Retention.prune(only: [:flush_receipts], batch_size: 2, max_items: 4)

    assert report.flush_receipts == 4
    assert reason.detail.max_items == 4
    assert TestRepo.aggregate(FlushReceipt, :count) == 6

    assert {:ok, %{flush_receipts: 6}} =
             Retention.prune(only: [:flush_receipts], batch_size: 2, max_items: 40)

    assert TestRepo.aggregate(FlushReceipt, :count) == 0
  end

  test "prune/1 reports a paused table rather than failing" do
    receipts!(3, @sixty_days)
    idle_heartbeat!("node_a")
    AuroraMeter.Operations.pause(Retention.operation(:flush_receipts))
    on_exit(fn -> AuroraMeter.Operations.resume(Retention.operation(:flush_receipts)) end)

    assert {:blocked, report, [%{table: :flush_receipts, reason: :paused}]} =
             Retention.prune(only: [:flush_receipts])

    assert report.flush_receipts == 0
    assert TestRepo.aggregate(FlushReceipt, :count) == 3
  end

  # ---------------------------------------------------------------------------
  # The receipt rule (I01). Not inside a describe block: ExUnit's full name is
  # "test <describe> <description>", so a describe would stop the invariant id
  # being the prefix (open-findings.md X196).
  # ---------------------------------------------------------------------------

  test "I01 a receipt is not pruned while a node's heartbeat reports an older pending batch" do
    receipts!(5, @sixty_days)
    idle_heartbeat!("node_a")
    pending_heartbeat!("node_b", @sixty_days + 86_400)

    assert {:blocked, report, [reason]} = Retention.prune(only: [:flush_receipts])

    assert report.flush_receipts == 0
    assert reason.reason == :node_liveness_unknown
    assert [%{node: "node_b", why: :pending_batch_older_than_cutoff}] = reason.detail.nodes
    assert TestRepo.aggregate(FlushReceipt, :count) == 5
  end

  test "I01 a receipt is not pruned while a node's heartbeat is itself older than the cutoff" do
    receipts!(5, @sixty_days)
    stale_idle_heartbeat!("node_b", @sixty_days + 86_400)

    assert {:blocked, report, [reason]} = Retention.prune(only: [:flush_receipts])

    assert report.flush_receipts == 0
    assert [%{node: "node_b", why: :heartbeat_stale}] = reason.detail.nodes
    assert TestRepo.aggregate(FlushReceipt, :count) == 5
  end

  test "I01 receipts are pruned when every node is idle and current" do
    old = receipts!(5, @sixty_days)
    young = receipts!(2, 3600)
    idle_heartbeat!("node_a")
    idle_heartbeat!("node_b")

    assert {:ok, %{flush_receipts: 5}} = Retention.prune(only: [:flush_receipts])

    remaining = TestRepo.all(FlushReceipt) |> Enum.map(& &1.id) |> Enum.sort()
    assert remaining == Enum.sort(young)
    refute Enum.any?(old, &(&1 in remaining))
  end

  test "I01 receipts are pruned when a node has a pending batch newer than the cutoff" do
    receipts!(5, @sixty_days)
    idle_heartbeat!("node_a")
    pending_heartbeat!("node_b", 600)

    assert {:ok, %{flush_receipts: 5}} = Retention.prune(only: [:flush_receipts])
    assert TestRepo.aggregate(FlushReceipt, :count) == 0
  end

  test "I01 a node with no heartbeat row does not block" do
    # node_b exists in the fleet and has never written a row, which is what a
    # node that has never applied a batch looks like: it holds no batch, so
    # there is no receipt of its that anything could retry.
    receipts!(5, @sixty_days)
    idle_heartbeat!("node_a")

    assert all_checkpoint_names() == ["flush:node_a"]
    assert {:ok, %{flush_receipts: 5}} = Retention.prune(only: [:flush_receipts])
  end

  test "I01 no heartbeat anywhere blocks a prune that would delete something" do
    # The upgrade hazard, closed mechanically rather than by documentation: a
    # fleet running the previous release writes no heartbeats at all, and
    # "nobody is reporting" is not evidence that nobody is holding a batch.
    receipts!(5, @sixty_days)

    assert {:blocked, report, [reason]} = Retention.prune(only: [:flush_receipts])

    assert report.flush_receipts == 0
    assert reason.reason == :no_heartbeats
    assert reason.detail.eligible == 5
    assert TestRepo.aggregate(FlushReceipt, :count) == 5

    # And it does not block an installation with nothing to delete, so a fresh
    # database is not reported as a problem.
    TestRepo.delete_all(FlushReceipt)
    assert {:ok, %{flush_receipts: 0}} = Retention.prune(only: [:flush_receipts])
  end

  test "I01 an unreadable pending_since blocks rather than being ignored" do
    receipts!(5, @sixty_days)
    idle_heartbeat!("node_a")
    Checkpoints.put("flush:node_b", %{"pending_since" => "not a timestamp"}, %{}, "pending")

    assert {:blocked, _report, [reason]} = Retention.prune(only: [:flush_receipts])
    assert [%{node: "node_b", why: :pending_since_unreadable}] = reason.detail.nodes
  end

  test "I01 a heartbeat state this release does not write blocks" do
    receipts!(5, @sixty_days)
    Checkpoints.put("flush:node_b", %{}, %{}, "gathering")

    assert {:blocked, _report, [reason]} = Retention.prune(only: [:flush_receipts])
    assert [%{node: "node_b", why: :unknown_state}] = reason.detail.nodes
  end

  test "I01 forget_node/1 removes the block for exactly one node and leaves the others" do
    receipts!(5, @sixty_days)
    idle_heartbeat!("node_a")
    pending_heartbeat!("node_b", @sixty_days + 86_400)
    pending_heartbeat!("node_c", @sixty_days + 86_400)

    assert {:blocked, _report, [reason]} = Retention.prune(only: [:flush_receipts])
    assert Enum.map(reason.detail.nodes, & &1.node) == ["node_b", "node_c"]

    assert {:ok, forgotten} = Retention.forget_node("node_b")
    assert forgotten.node == "node_b"
    assert forgotten.state == "pending"

    # One node forgotten, one still blocking, and the third untouched.
    assert {:blocked, _report, [reason]} = Retention.prune(only: [:flush_receipts])
    assert Enum.map(reason.detail.nodes, & &1.node) == ["node_c"]
    assert all_checkpoint_names() == ["flush:node_a", "flush:node_c"]

    assert {:ok, _} = Retention.forget_node("node_c")
    assert {:ok, %{flush_receipts: 5}} = Retention.prune(only: [:flush_receipts])
  end

  test "I01 a node id containing an @ is handled, which is what every real node id looks like" do
    # Found by running the retention pass against a real Stripe test-mode run
    # (docs/evidence/v1/phase-05/05d-real-provider.md): every node id this
    # package will actually see contains an `@`, because `to_string(node())` is
    # `"nonode@nohost"` on an unnamed VM and `"app@10.0.1.7"` on a named one,
    # and every synthetic fixture in this file used `node_a`.
    #
    # It is also why the heartbeat row goes through `AuroraMeter.Checkpoints`
    # rather than `AuroraMeter.Operations`: `@` is not in an operation name's
    # character class, so `put_checkpoint/2` would raise on the first heartbeat
    # of every default installation (open-findings.md X221).
    receipts!(5, @sixty_days)
    idle_heartbeat!("nonode@nohost")

    assert all_checkpoint_names() == ["flush:nonode@nohost"]

    status = Retention.status()
    assert [%{node: "nonode@nohost", blocks: false}] = status.heartbeats

    assert {:ok, %{flush_receipts: 5}} = Retention.prune(only: [:flush_receipts])

    # And the same id round trips through forget_node/1, which builds the row
    # name back from it.
    idle_heartbeat!("app@10.0.1.7")
    assert {:ok, %{node: "app@10.0.1.7"}} = Retention.forget_node("app@10.0.1.7")
    assert all_checkpoint_names() == ["flush:nonode@nohost"]
  end

  test "I01 forget_node/1 refuses a node it has never heard of" do
    assert {:error, :not_found} = Retention.forget_node("node_that_never_was")
  end

  test "I01 a retry of a batch whose receipt was pruned would double count" do
    # THE NEGATIVE CONTROL, and it is written as a demonstration rather than as
    # a regression: it is the whole reason the receipt rule exists, so it has to
    # be shown rather than assumed. The receipt is removed **directly**, not
    # through prune/1, because prune/1 correctly refuses to remove it. The next
    # test is the same scenario with the rule doing its job.
    tenant = unique_tenant("retain")
    id = Ecto.UUID.generate()
    counters = [counter_delta(tenant, 5)]

    assert {:ok, %{counters: [%{value: 5}]}} = flush_batch(id, counters)

    # A retry with the receipt in place: the deltas are NOT applied again.
    assert {:ok, %{counters: [%{value: 5}]}} = flush_batch(id, counters)

    assert {1, _} = TestRepo.delete_all(from(r in FlushReceipt, where: r.id == ^id))

    assert {:ok, %{counters: [%{value: 10}]}} = flush_batch(id, counters),
           "deleting a receipt must reopen the double-count window, or this control " <>
             "proves nothing about why the receipt rule exists"
  end

  test "I01 a retry of a batch whose receipt was protected does not double count" do
    tenant = unique_tenant("retain")
    id = Ecto.UUID.generate()
    counters = [counter_delta(tenant, 5)]

    assert {:ok, %{counters: [%{value: 5}]}} = flush_batch(id, counters)

    # Age the receipt past the window and put the fleet in exactly the state the
    # rule exists for: one node still holding a batch older than the cutoff.
    age_receipt!(id, @sixty_days)
    pending_heartbeat!("node_b", @sixty_days + 86_400)

    assert {:blocked, %{flush_receipts: 0}, _reasons} = Retention.prune(only: [:flush_receipts])
    assert TestRepo.get(FlushReceipt, id)

    assert {:ok, %{counters: [%{value: 5}]}} = flush_batch(id, counters)
  end

  # ---------------------------------------------------------------------------
  # status/0 and the ambiguity warnings
  # ---------------------------------------------------------------------------

  test "status/0 lists every node, its state and the version it is running" do
    idle_heartbeat!("node_a")
    pending_heartbeat!("node_b", @sixty_days + 86_400)

    status = Retention.status()

    assert Enum.map(status.heartbeats, & &1.node) == ["node_a", "node_b"]
    assert Enum.map(status.heartbeats, & &1.blocks) == [false, true]
    assert status.versions == [Retention.package_version()]
    assert %DateTime{} = status.cutoff
  end

  test "plan/1 warns when the fleet files everything under nonode@nohost" do
    receipts!(1, @sixty_days)
    idle_heartbeat!("nonode@nohost")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = Retention.plan([])
      end)

    assert log =~ "nonode@nohost"
    assert log =~ ":flush_node_id"
  end

  test "plan/1 warns when the fleet reports more than one package version" do
    receipts!(1, @sixty_days)
    idle_heartbeat!("node_a")
    Checkpoints.put("flush:node_b", %{"version" => "0.4.0"}, %{}, "idle")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = Retention.plan([])
      end)

    assert log =~ "different Aurora Meter versions"
    assert log =~ "0.4.0"
  end

  # ---------------------------------------------------------------------------
  # Fixtures and helpers
  # ---------------------------------------------------------------------------

  defp flush_batch(id, counters), do: EctoStorage.flush_batch(id, counters, [])

  defp counter_delta(tenant, delta) do
    %{
      tenant_key: tenant,
      feature: :ops,
      period_start: ~U[2026-09-01 00:00:00Z],
      delta: delta
    }
  end

  defp populate!(tenant) do
    now = DateTime.utc_now()

    TestRepo.insert!(%Counter{
      tenant_key: tenant,
      feature: "ops",
      period_start: @two_years_ago_sec,
      value: 5,
      inserted_at: @two_years_ago,
      updated_at: @two_years_ago
    })

    TestRepo.insert!(%History{
      tenant_key: tenant,
      feature: "ops",
      bucket_kind: "day",
      bucket_start: ~D[2024-09-15],
      value: 5,
      inserted_at: @two_years_ago,
      updated_at: @two_years_ago
    })

    TestRepo.insert!(%Subscription{
      tenant_key: tenant,
      plan_id: "pro",
      status: "active",
      inserted_at: @two_years_ago,
      updated_at: @two_years_ago
    })

    TestRepo.insert!(%CreditBalance{
      tenant_key: tenant,
      balance: 1_000,
      inserted_at: @two_years_ago,
      updated_at: @two_years_ago
    })

    TestRepo.insert!(%CreditTransaction{
      tenant_key: tenant,
      kind: :grant,
      category: :paid,
      amount: 1_000,
      balance_after: 1_000,
      held_after: 0,
      reference: "retain_#{System.unique_integer([:positive])}",
      inserted_at: @two_years_ago
    })

    TestRepo.insert!(%Event{
      tenant_key: tenant,
      feature: "ops",
      quantity: 1,
      event_id: "retain_#{System.unique_integer([:positive])}",
      payload_hash: :crypto.hash(:sha256, "retain"),
      occurred_at: @two_years_ago,
      period_start: @two_years_ago_sec,
      inserted_at: @two_years_ago
    })

    TestRepo.insert!(%EventTotal{
      tenant_key: tenant,
      feature: "ops",
      period_start: @two_years_ago_sec,
      generation: 0,
      quantity: 1,
      events: 1,
      inserted_at: @two_years_ago,
      updated_at: @two_years_ago
    })

    _ = now

    Map.new(@protected_schemas, &{&1, TestRepo.aggregate(&1, :count)})
  end

  # Receipts stamped `seconds` in the past. `insert_all` rather than the
  # Storage adapter, because these are fixtures for the age predicate and not a
  # flush.
  defp receipts!(count, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    rows =
      for _ <- 1..count do
        %{id: Ecto.UUID.generate(), inserted_at: at}
      end

    {^count, _} = TestRepo.insert_all(FlushReceipt, rows)

    Enum.map(rows, & &1.id)
  end

  defp age_receipt!(id, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)
    TestRepo.update_all(from(r in FlushReceipt, where: r.id == ^id), set: [inserted_at: at])
  end

  defp idle_heartbeat!(node_id) do
    Checkpoints.put(
      "flush:#{node_id}",
      %{"version" => Retention.package_version()},
      %{},
      "idle"
    )
  end

  defp pending_heartbeat!(node_id, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    Checkpoints.put(
      "flush:#{node_id}",
      %{
        "pending_since" => DateTime.to_iso8601(at),
        "batch_id" => Ecto.UUID.generate(),
        "version" => Retention.package_version()
      },
      %{},
      "pending"
    )
  end

  # An idle row whose own `updated_at` is old. `updated_at` is stamped by the
  # database in `Checkpoints.put/5`, so it has to be moved with a statement of
  # its own rather than passed in.
  defp stale_idle_heartbeat!(node_id, seconds_ago) do
    idle_heartbeat!(node_id)
    age!("flush:#{node_id}", DateTime.add(DateTime.utc_now(), -seconds_ago, :second))
  end

  defp age!(name, %DateTime{} = at) do
    TestRepo.query!(
      "UPDATE aurora_meter_checkpoints SET updated_at = $1 WHERE name = $2",
      [DateTime.to_naive(at), name]
    )
  end

  defp clear_heartbeats! do
    TestRepo.query!("DELETE FROM aurora_meter_checkpoints WHERE name LIKE 'flush:%'", [])
  end

  defp all_checkpoint_names do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT name FROM aurora_meter_checkpoints WHERE name LIKE 'flush:%' ORDER BY name",
        []
      )

    List.flatten(rows)
  end

  # The tables the migrations actually create, read out of the source rather
  # than listed here, so a table added by a later version is seen without an
  # edit to this file.
  defp tables_the_migrations_create do
    ["lib/aurora_meter/migration.ex" | Path.wildcard("lib/aurora_meter/migration/*.ex")]
    |> Enum.flat_map(fn path ->
      ~r/create_if_not_exists table\(:(aurora_meter_[a-z_]+)/
      |> Regex.scan(File.read!(path), capture: :all_but_first)
      |> List.flatten()
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
