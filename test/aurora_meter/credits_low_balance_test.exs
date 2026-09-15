defmodule AuroraMeter.CreditsLowBalanceTest do
  @moduledoc """
  One low-balance alert per crossing, and a handler that cannot fail, block or
  delay a write (build unit 06c, V1 task 06.07, lower-level invariants LI-06c-1
  and LI-06c-2).

  The two things this file exists to prove are counts, not occurrences. "The
  wallet crossed" is true of the old behaviour too; what is new is that it
  crossed **once** while it stayed below the line, that the crossing carries an
  identity which is stable across those writes, and that a second genuine
  crossing carries a different one.

  ## What each claim is asserted on, and why they are different things

  A **crossing** is a decision the ledger takes inside the transaction that
  moved the balance, and it says so by broadcasting
  `{:aurora_meter, :low_balance, event}` **synchronously**, in the writer, before
  anything else. Counting those broadcasts is therefore exact: when the six
  writes have returned, every broadcast that will ever happen is already in this
  process's mailbox. Every count below is a count of broadcasts.

  **Delivery** to `:credits_low_balance_handler` is a separate thing, and after
  finding X269 it happens in a watcher process rather than in the writer, so it
  is asynchronous. It is asserted with `assert_receive`, never by reading a
  count back immediately after a write, which would be a race dressed up as a
  measurement.

  Separating them is not a convenience. The crossing is a property of the
  ledger; the handler is a delivery mechanism that is documented as at most
  once. A test that measured the first by counting the second would fail for
  the wrong reason the day the second became lossy.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Test.Config, as: TestConfig

  @dollar 1_000_000
  @past ~U[2020-01-01 00:00:00Z]

  # A handler that says it ran, to this process, and records the event. It takes
  # no database connection, deliberately: what is under test is that it is
  # invoked, and a handler that queried would be testing the pool.
  defp recording_handler do
    parent = self()
    fn event -> send(parent, {:handler_ran, event}) end
  end

  test "I11 the low-balance handler fires once per crossing and not again while below the threshold" do
    tenant = unique_tenant("lowbal")
    :ok = Credits.subscribe(tenant)

    TestConfig.with_config(
      [{:aurora_meter, :credits_low_balance_handler, recording_handler()}],
      fn ->
        {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
        {:ok, _} = Credits.set_low_balance_threshold(tenant, 5 * @dollar)

        # The crossing.
        {:ok, _} = Credits.debit(tenant, 6 * @dollar, "d0")

        # Five more debits while below it. Under a rule that compared two figures
        # per write, a reconciliation cycle that recovers and falls again inside
        # one pass alerts on each fall; the crossing flag is what makes this one.
        for i <- 1..5, do: {:ok, _} = Credits.debit(tenant, 1000, "d#{i}")

        crossings = crossings(tenant)

        assert length(crossings) == 1, "the wallet crossed #{length(crossings)} times, not once"
        assert hd(crossings).threshold == 5 * @dollar
        assert hd(crossings).spendable == 4 * @dollar

        # One standing crossing, and it is the transaction that caused it.
        crossing = crossing_id(tenant)
        assert crossing
        assert hd(crossings).crossing_id == crossing

        # Stable across the five later writes: the flag is not rewritten by each
        # of them, which is what makes "one alert per crossing" a property of the
        # row rather than of the order the writes happened to arrive in. This
        # assertion is independently load bearing: control C1b measured that it
        # fails on its own when the flag is ignored, even with the count relaxed.
        assert crossing_id(tenant) == crossing

        # And the handler really was invoked, once, for that crossing. Asserted
        # rather than tolerated (X269): a handler that never ran must fail here.
        assert_receive {:handler_ran, %{crossing_id: ^crossing}}, 2_000
        refute_receive {:handler_ran, _}, 200
      end
    )
  end

  test "I11 a recovery above the threshold then a second crossing fires twice with different crossing ids" do
    tenant = unique_tenant("lowbal")
    :ok = Credits.subscribe(tenant)

    TestConfig.with_config(
      [{:aurora_meter, :credits_low_balance_handler, recording_handler()}],
      fn ->
        {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
        {:ok, _} = Credits.set_low_balance_threshold(tenant, 5 * @dollar)

        {:ok, _} = Credits.debit(tenant, 6 * @dollar, "fall-1")
        first = crossing_id(tenant)
        assert first

        # Back up: the flag is cleared and **no alert is sent on the way up**.
        {:ok, _} = Credits.grant(tenant, 6 * @dollar, reference: "topup")
        assert crossing_id(tenant) == nil
        assert length(crossings(tenant)) == 1

        {:ok, _} = Credits.debit(tenant, 6 * @dollar, "fall-2")
        second = crossing_id(tenant)

        crossings = crossings(tenant)
        assert length(crossings) == 1, "the recovery itself alerted"
        assert second != first, "the second crossing reused the first crossing's id"
        assert hd(crossings).crossing_id == second

        assert_receive {:handler_ran, %{crossing_id: ^first}}, 2_000
        assert_receive {:handler_ran, %{crossing_id: ^second}}, 2_000
        refute_receive {:handler_ran, _}, 200
      end
    )
  end

  test "I11 a replayed reconciliation cycle that re-crosses the same threshold fires once" do
    tenant = unique_tenant("lowbal")
    :ok = Credits.subscribe(tenant)

    TestConfig.with_config(
      [{:aurora_meter, :credits_low_balance_handler, recording_handler()}],
      fn ->
        {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
        {:ok, _} = Credits.set_low_balance_threshold(tenant, 5 * @dollar)
        {:ok, txn} = Credits.debit(tenant, 6 * @dollar, "webhook:evt_1")

        # The same webhook delivered twice. The ledger deduplicates on the
        # reference, so the second delivery moves nothing...
        assert {:error, :duplicate_reference} =
                 Credits.debit(tenant, 6 * @dollar, "webhook:evt_1")

        # ...and a grant redelivery, which returns the original entry rather than
        # refusing, is the shape that could have alerted a second time: it reaches
        # `emit/1` with an outcome. A duplicate is refused a crossing evaluation
        # outright.
        {:ok, _} = Credits.grant(tenant, @dollar, reference: "pay_1")
        assert {:ok, _} = Credits.grant(tenant, @dollar, reference: "pay_1")

        crossings = crossings(tenant)
        assert length(crossings) == 1
        assert hd(crossings).crossing_id == txn.id

        assert_receive {:handler_ran, %{crossing_id: _}}, 2_000
        refute_receive {:handler_ran, _}, 200
      end
    )
  end

  test "I11 a raising low-balance handler does not fail the ledger write" do
    tenant = unique_tenant("lowbal")
    parent = self()

    handler = fn event ->
      send(parent, {:handler_ran, event})
      raise "the host's handler is broken"
    end

    TestConfig.with_config([{:aurora_meter, :credits_low_balance_handler, handler}], fn ->
      {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
      {:ok, _} = Credits.set_low_balance_threshold(tenant, 5 * @dollar)

      attach_low_balance(tenant)

      # The write returns `{:ok, txn}`, not the handler's exception.
      assert {:ok, txn} = Credits.debit(tenant, 6 * @dollar, "d0")
      assert txn.kind == :debit

      # ...and it is committed.
      assert Credits.balance(tenant).balance == 4 * @dollar
      assert [%{reference: "d0"}] = Credits.history(tenant, kinds: [:debit])

      assert_receive {:handler_ran, _event}, 2_000
      assert_receive {:low_balance, _measurements, %{handler: :raised}}, 2_000

      # The crossing is recorded even though no alert was delivered: the flag
      # means "this crossing has been decided", so a broken handler does not
      # re-alert on every later write. Documented as at-most-once.
      assert crossing_id(tenant)
    end)
  end

  test "I11 a low-balance handler that never returns is shut down at the timeout and the write stands" do
    tenant = unique_tenant("lowbal")
    parent = self()

    handler = fn _event ->
      send(parent, :handler_started)
      Process.sleep(:infinity)
    end

    TestConfig.with_config(
      [
        {:aurora_meter, :credits_low_balance_handler, handler},
        {:aurora_meter, :credits_low_balance_handler_timeout, 50}
      ],
      fn ->
        {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
        {:ok, _} = Credits.set_low_balance_threshold(tenant, 5 * @dollar)

        attach_low_balance(tenant)

        started = System.monotonic_time(:millisecond)
        assert {:ok, _txn} = Credits.debit(tenant, 6 * @dollar, "d0")
        elapsed = System.monotonic_time(:millisecond) - started

        assert_receive :handler_started, 2_000
        assert_receive {:low_balance, _measurements, %{handler: :timeout}}, 2_000

        # **The caller did not wait at all**, which is stronger than the bound
        # the configuration key promises and is the point of X269: the writer
        # may be holding a pinned connection, and the handler may want one.
        # A generous ceiling rather than a tight one, because this asserts "did
        # not wait for the handler", not "was fast".
        assert elapsed < 50,
               "the caller waited #{elapsed}ms for a handler it must not wait for at all"

        assert Credits.balance(tenant).balance == 4 * @dollar
      end
    )
  end

  test "I11 the low-balance trigger uses spendable, not balance minus held" do
    # A wallet whose only funds are on an expired lot has `available` well above
    # its threshold and nothing it can spend. Under the old figure it was not
    # low; under `spendable` it is, and it is.
    tenant = unique_tenant("lowbal")
    Ledger.enable_lots!(tenant)
    :ok = Credits.subscribe(tenant)

    TestConfig.with_config(
      [{:aurora_meter, :credits_low_balance_handler, recording_handler()}],
      fn ->
        {:ok, _} =
          Credits.grant(tenant, 10 * @dollar,
            reference: "stale",
            category: :promotional,
            expires_at: @past
          )

        {:ok, _} = Credits.set_low_balance_threshold(tenant, 5 * @dollar)
        {:ok, _} = Credits.grant(tenant, 1000, reference: "dust")

        snapshot = Credits.balance(tenant)
        assert snapshot.available == 10 * @dollar + 1000
        assert snapshot.spendable == 1000

        crossings = crossings(tenant)
        assert length(crossings) == 1
        assert hd(crossings).spendable == 1000
        # The old figure is still reported, and it is the one that would not have
        # triggered: this is the assertion that fails if `spendable` is a copy of
        # `available`.
        assert hd(crossings).available == 10 * @dollar + 1000

        assert_receive {:handler_ran, %{spendable: 1000}}, 2_000
      end
    )
  end

  test "I11 lowering the threshold below the current spendable clears the standing crossing" do
    tenant = unique_tenant("lowbal")
    :ok = Credits.subscribe(tenant)

    TestConfig.with_config(
      [{:aurora_meter, :credits_low_balance_handler, recording_handler()}],
      fn ->
        {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
        {:ok, _} = Credits.set_low_balance_threshold(tenant, 5 * @dollar)
        {:ok, _} = Credits.debit(tenant, 6 * @dollar, "d0")

        first = crossing_id(tenant)
        assert first
        assert length(crossings(tenant)) == 1

        # The operator decides 4 USD was never low. Lowering the threshold below
        # the wallet clears the standing crossing and alerts nobody: nothing about
        # the wallet moved.
        {:ok, row} = Credits.set_low_balance_threshold(tenant, 2 * @dollar)
        assert row.low_balance_crossing_id == nil
        assert crossing_id(tenant) == nil
        assert crossings(tenant) == []

        # ...and the next genuine fall below the new line alerts, with a new id,
        # which is what a flag left standing would have swallowed.
        {:ok, _} = Credits.debit(tenant, 3 * @dollar, "d1")
        crossings = crossings(tenant)
        assert length(crossings) == 1
        assert hd(crossings).crossing_id != first
        assert hd(crossings).threshold == 2 * @dollar

        # Clearing the threshold clears the flag too, so a wallet cannot keep a
        # crossing for a threshold that no longer exists.
        {:ok, _} = Credits.set_low_balance_threshold(tenant, nil)
        assert crossing_id(tenant) == nil
      end
    )
  end

  test "I11 no threshold means no crossing, no alert and no flag" do
    tenant = unique_tenant("lowbal")
    :ok = Credits.subscribe(tenant)

    TestConfig.with_config(
      [{:aurora_meter, :credits_low_balance_handler, recording_handler()}],
      fn ->
        {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
        {:ok, _} = Credits.debit(tenant, 9 * @dollar, "d0")

        assert crossings(tenant) == []
        assert crossing_id(tenant) == nil
        refute_receive {:handler_ran, _}, 200
      end
    )
  end

  test "I11 a handler that needs a connection gets one while the writer holds a pinned one (X269)" do
    # **The regression for X269, and it is the shape Pro's payment paths use.**
    # `AuroraMeter.Pro.Lock.with_lock/2` wraps a ledger call in
    # `Repo.checkout/1`, which pins a connection to the writer for the length of
    # the callback. While the writer waited for the handler, the handler waited
    # for a connection the writer was holding, and under the single connection a
    # sandbox gives a test that is a deadlock resolved only by the checkout
    # queue's own timeout, after which the handler was reported as `:raised` and
    # nothing was delivered. Two Pro tests passed on exactly that, asserting
    # `refute_enqueued` against a handler that had crashed.
    #
    # The handler here does what Pro's does: it reads the database.
    tenant = unique_tenant("lowbal")
    parent = self()

    handler = fn event ->
      send(parent, {:handler_read, Credits.balance(event.tenant_key).balance})
    end

    TestConfig.with_config([{:aurora_meter, :credits_low_balance_handler, handler}], fn ->
      {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
      {:ok, _} = Credits.set_low_balance_threshold(tenant, 5 * @dollar)

      attach_low_balance(tenant)

      assert {:ok, _txn} =
               TestRepo.checkout(fn ->
                 TestRepo.query!("SELECT 1", [])
                 Credits.debit(tenant, 6 * @dollar, "d0")
               end)

      # The handler ran, reached the database and finished. Before X269 this
      # timed out and the event carried `handler: :raised`.
      assert_receive {:handler_read, 4_000_000}, 5_000
      assert_receive {:low_balance, _measurements, %{handler: :ok}}, 5_000
    end)
  end

  # -- helpers ----------------------------------------------------------------

  # Every crossing this process has been told about, oldest first. The broadcast
  # is synchronous in the writer, so once the writes have returned the mailbox
  # holds every one that will ever arrive and the count is exact rather than
  # eventual.
  defp crossings(tenant) do
    tenant_key = AuroraMeter.Tenant.to_key(tenant)
    drain_crossings(tenant_key, [])
  end

  defp drain_crossings(tenant_key, acc) do
    receive do
      {:aurora_meter, :low_balance, %{tenant_key: ^tenant_key} = event} ->
        drain_crossings(tenant_key, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp crossing_id(tenant) do
    TestRepo.get_by!(CreditBalance, tenant_key: tenant).low_balance_crossing_id
  end

  defp attach_low_balance(tenant) do
    id = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:aurora_meter, :credits, :low_balance],
        fn _event, measurements, metadata, _config ->
          if metadata.tenant_key == tenant,
            do: send(parent, {:low_balance, measurements, metadata})

          :ok
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
