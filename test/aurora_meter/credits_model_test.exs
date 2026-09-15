defmodule AuroraMeter.CreditsModelTest do
  @moduledoc """
  I10: the pure ledger model, the generated histories that compare it with the
  real database after every step, and the integer-bound cases the property
  deliberately stays away from (build unit 01e).

  The model self-tests in the first block need no database and pin the model
  against cases whose answer is obvious without reading either implementation.
  They exist because a model that is wrong in the same way as the ledger proves
  nothing, and they are written first for the same reason: a generator built on
  an unverified model produces confident nonsense.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  # The default 60 s per test is the *default* configuration's budget, where the
  # whole file takes nine seconds. The deep configuration runs twenty times as
  # many histories (`AURORA_PROPERTY_RUNS=500`) and a timeout there kills the
  # test process mid-history, which leaves committed rows behind and turns one
  # slow property into a module-wide conservation failure. Ten minutes covers
  # the deep run with room; it is a guard against a hang, not a budget.
  @moduletag timeout: 600_000

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Money
  alias AuroraMeter.Credits.Promotions
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.FaultRepo
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.LedgerCommands
  alias AuroraMeter.Test.LedgerModel

  @oct ~U[2026-10-01 00:00:00Z]
  @dec ~U[2026-12-01 00:00:00Z]
  @dollar 1_000_000

  # 2^63 - 1: the largest value a `bigint` column holds (`migration.ex:259`).
  @bigint_max 9_223_372_036_854_775_807

  # Every history must leave the tables exactly as it found them. 01b's
  # `cleanup!/1` is prefix bounded and refuses a short prefix, so this is the
  # check that it was actually called rather than that it is safe.
  setup_all do
    Connections.checkout!()

    # A run that was killed mid-history (an interrupt, or a property that hit its
    # timeout) leaves committed rows under this unit's own `model_` tenants. The
    # next run's prefix-bounded cleanup would then delete rows it did not create
    # and fail the conservation check below for the wrong reason, so they are
    # cleared first. `model` is registered rather than assumed: 01b's guard
    # refuses any prefix it was not told about, and this unit is the only owner
    # of that one (`AuroraMeter.Test.unique_tenant("model")`, here and in
    # `LedgerCommands.run/2`).
    Connections.register_prefix("model")
    Connections.cleanup!("model")

    before = Connections.row_counts()

    on_exit(fn ->
      Connections.checkout!()
      remaining = Connections.row_counts()

      if remaining != before do
        raise "#{inspect(__MODULE__)} left rows behind: #{inspect(before)} -> #{inspect(remaining)}"
      end

      # Silence is never read as success: a run whose properties covered fewer
      # histories than they asked for says so, on stdout, with the timestamps.
      report_clock_steps()

      # And the cross-oracle property has to have actually compared something.
      # It is allowed to diverge (06a has two documented divergences from 01e's
      # view), but a run in which EVERY history diverged compared nothing and
      # would be green for the wrong reason.
      counts = cross_oracle_counts()

      if counts.compared + counts.diverged > 0 and counts.compared == 0 do
        raise "the cross-oracle property diverged on all #{counts.diverged} histories and " <>
                "compared none of them, so it proved nothing about 06a's allocator against " <>
                "01e's independent model"
      end

      IO.puts("[06a cross-oracle] compared: #{counts.compared}, diverged: #{counts.diverged}")

      :persistent_term.erase({__MODULE__, :cross_oracle})
    end)

    :ok
  end

  describe "the model itself" do
    test "model: a grant then a hold then a settle below the hold leaves the difference spendable" do
      model =
        play([
          {:grant, "g1", @dollar, :paid, nil},
          {:hold, "h1", 600_000},
          {:settle, "h1", 250_000}
        ])

      assert LedgerModel.projections(model) == %{
               balance: 750_000,
               held: 0,
               available: 750_000,
               promotional: 0,
               debt: 0,
               expired: 0
             }

      assert LedgerModel.open_holds(model) == %{}
      assert LedgerModel.self_check(model) == []
    end

    test "model: a settle above the hold takes the balance negative and flags an overrun" do
      # ledger.ex:167: `overrun` is set when `actual > hold.held_delta`, and
      # settle never refuses for want of balance (credits.ex:320-323).
      model =
        play([
          {:grant, "g1", 100_000, :paid, nil},
          {:hold, "h1", 100_000},
          {:settle, "h1", 250_000}
        ])

      assert model.balance == -150_000
      assert model.held == 0
      assert LedgerModel.closed_holds(model)["h1"].overrun? == true
      assert LedgerModel.closed_holds(model)["h1"].settled_amount == 250_000
    end

    test "model: a reversal does not consume the promotional figure" do
      # ledger.ex:477-481: refunding a paid top-up must not quietly spend the
      # trial grant, or there would be nothing left for the expirer to reclaim.
      reversed =
        play([
          {:grant, "promo", @dollar, :promotional, nil},
          {:grant, "paid", @dollar, :paid, nil},
          {:reverse, "refund", @dollar}
        ])

      debited =
        play([
          {:grant, "promo", @dollar, :promotional, nil},
          {:grant, "paid", @dollar, :paid, nil},
          {:debit, "spend", @dollar}
        ])

      assert reversed.balance == debited.balance
      assert reversed.promotional == @dollar
      assert debited.promotional == 0
    end

    test "model: a duplicate grant reference is a duplicate, not a second grant" do
      # ledger.ex:96-98 and :112: the reference is checked under the balance
      # row's lock and a hit returns the existing entry with no write.
      {model, first} = LedgerModel.apply(LedgerModel.new(), {:grant, "g1", @dollar, :paid, nil})
      {model, second} = LedgerModel.apply(model, {:grant, "g1", 500_000, :paid, nil})

      assert first == {:ok, :new}
      assert second == {:ok, :duplicate}
      assert model.balance == @dollar
      assert length(model.entries) == 1
    end

    test "model: a hold, a debit and a reversal each have their own reference namespace (L2)" do
      model = play([{:grant, "g1", @dollar, :paid, nil}])

      {model, held} = LedgerModel.apply(model, {:hold, "x", 100_000})
      {model, debited} = LedgerModel.apply(model, {:debit, "x", 100_000})
      {model, reversed} = LedgerModel.apply(model, {:reverse, "x", 1})
      {model, again} = LedgerModel.apply(model, {:reverse, "x", 1})

      assert held == :ok
      assert debited == :ok
      # Until build unit 06c this line read `{:error, :duplicate_reference}`:
      # `reverse/4` went through `Ledger.debit/5` and landed in the `:debit`
      # half of the `(kind, reference)` index, which was finding L2. It writes
      # `kind: :reverse` now, so all three namespaces are separate.
      assert reversed == :ok
      # ...and idempotency inside the new namespace is unchanged, which is the
      # half a "they no longer collide" change could quietly lose.
      assert again == {:error, :duplicate_reference}
      assert model.balance == 899_999
    end

    test "model: promotional is clamped to the balance and never negative" do
      # ledger.ex:439-444 re-establishes 0 <= promotional <= max(balance, 0)
      # after every entry, which is what lets expire_due/1 never go negative.
      model =
        play([
          {:grant, "paid", @dollar, :paid, nil},
          {:grant, "promo", 500_000, :promotional, nil},
          {:reverse, "r1", 1_400_000}
        ])

      assert model.balance == 100_000
      assert model.promotional == 100_000

      deeper = replay(model, [{:reverse, "r2", 200_000}])

      assert deeper.balance == -100_000
      assert deeper.promotional == 0
      assert LedgerModel.self_check(deeper) == []
    end

    test "model: attribution spends the soonest-expiring grant first, then the oldest, then by id" do
      # promotions.ex:48-61 sorts by {expiry_key, inserted_at, id}, so the grant
      # issued first is not necessarily the one spent first.
      model =
        play([
          {:grant, "december", @dollar, :promotional, @dec},
          {:grant, "october", 500_000, :promotional, @oct},
          {:debit, "spend", 600_000}
        ])

      assert LedgerModel.remainders(model) == %{"october" => 0, "december" => 900_000}
      assert model.promotional == 900_000
    end

    test "model: a non-expiring grant is spent last within its category" do
      # promotions.ex:63: expiry_key(nil) is {1, 0}, which sorts after every
      # real expiry instant however far away.
      model =
        play([
          {:grant, "forever", @dollar, :promotional, nil},
          {:grant, "october", 500_000, :promotional, @oct},
          {:debit, "spend", 600_000}
        ])

      assert LedgerModel.remainders(model) == %{"october" => 0, "forever" => 900_000}
    end

    test "model: expiry takes the minimum of the grant's remainder, the promotional figure and the spendable balance" do
      # ledger.ex:296-298: min(remaining, row.promotional, max(balance - held, 0)).
      {model, result} =
        [{:grant, "promo", @dollar, :promotional, @oct}, {:hold, "h1", 400_000}]
        |> play()
        |> LedgerModel.apply({:expire_due, @dec})

      assert result == {:ok, 1}
      assert model.balance == 400_000
      assert model.promotional == 400_000
      assert LedgerModel.remaining(model, "promo") == 400_000
      # ledger.ex:321-323: expired_at is stamped only when the whole remainder
      # went, so a later pass finishes the job once the hold closes.
      assert model.grants["promo"].expired_at == nil
    end

    test "model: expiry refuses with :held when the whole remainder is reserved" do
      # ledger.ex:304-305: rather than write a zero-value row every pass until
      # the work settles, the grant is left alone and expire_due/1 counts it as
      # not expired.
      {model, result} =
        [{:grant, "promo", @dollar, :promotional, @oct}, {:hold, "h1", @dollar}]
        |> play()
        |> LedgerModel.apply({:expire_due, @dec})

      assert result == {:ok, 0}
      assert Enum.all?(model.entries, &(&1.kind != :expire))
      assert model.balance == @dollar
      assert model.promotional == @dollar
    end
  end

  describe "the dormant lot view" do
    test "lot view: every lot conserves amount across available, reserved, consumed, reversed and expired" do
      view =
        [
          {:grant, "promo", @dollar, :promotional, @oct},
          {:grant, "paid", 2_000_000, :paid, nil},
          {:hold, "h1", 1_500_000},
          {:settle, "h1", 900_000},
          {:debit, "d1", 250_000},
          {:expire_due, @dec},
          {:grant, "adj", 100_000, :adjustment, nil},
          {:reverse, "r1", 1_800_000}
        ]
        |> play()
        |> LedgerModel.lot_view()

      assert LedgerModel.v8_problems(view) == []
      assert Enum.all?(view.lots, &(&1.amount > 0))
    end

    test "lot view: released value on an expired lot becomes expired, not spendable (the L1 difference 06a will land)" do
      model =
        play([
          {:grant, "promo", @dollar, :promotional, @oct},
          {:hold, "h1", 400_000},
          {:expire_due, @dec},
          {:release, "h1"}
        ])

      view = LedgerModel.lot_view(model)

      # Today's flat ledger hands the released reservation back as spendable
      # even though its grant expired (finding L1, ledger.ex:296-305 with
      # :174-195).
      assert model.balance - model.held == 400_000
      # The lot design writes it off instead: nothing of an expired lot is ever
      # spendable again.
      assert view.available == 0
      assert view.expired == @dollar
      # `released_expired` is the L1 measure on its own: value that was reserved
      # when its lot expired. `leak` is the raw difference between the two
      # spendable figures and also carries this view's other, deliberate
      # divergences from today's ledger, so the evidence quotes both.
      assert view.released_expired == 400_000
      assert view.leak == 400_000
      assert LedgerModel.v8_problems(view) == []
    end

    test "lot view: a paid reversal never touches a promotional lot" do
      view =
        [
          {:grant, "promo", 500_000, :promotional, nil},
          {:grant, "paid", @dollar, :paid, nil},
          {:reverse, "refund", 600_000}
        ]
        |> play()
        |> LedgerModel.lot_view()

      promotional = Enum.find(view.lots, &(&1.category == :promotional))
      paid = Enum.find(view.lots, &(&1.category == :paid))

      assert promotional.available == 500_000
      assert promotional.reversed == 0
      assert paid.reversed == 600_000
      assert view.promotional == 500_000
      assert LedgerModel.v8_problems(view) == []
    end
  end

  describe "generated histories" do
    setup do
      # One non-sandbox connection for the whole property, so `run/2` never
      # takes or returns one per history and the aggregates below can be read
      # after it returns.
      Connections.checkout!()
      :ok
    end

    property "I10 a generated history of grants, holds, settles, releases, debits and reversals matches the pure model" do
      check all(
              history <- LedgerCommands.history(expiry: false),
              max_runs: LedgerCommands.runs()
            ) do
        LedgerCommands.run(history, seed: seed(), label: "no-expiry history")
      end
    end

    property "I10 a generated history including expiry matches the pure model" do
      check all(history <- LedgerCommands.history(), max_runs: LedgerCommands.runs()) do
        LedgerCommands.run(history, seed: seed(), label: "expiry history")
      end
    end

    property "I10 balance equals the sum of every transaction amount after every step" do
      check_law("V1", fn model, aggregates ->
        assert aggregates.amount_sum == aggregates.row.balance
        assert aggregates.row.balance == model.balance
      end)
    end

    property "I10 held equals the sum of open holds after every step" do
      check_law("V2", fn model, aggregates ->
        assert aggregates.held_delta_sum == aggregates.row.held
        assert aggregates.open_holds_sum == aggregates.row.held
        assert aggregates.row.held == model.held
      end)
    end

    property "I10 the newest row's snapshot columns equal the balance row" do
      check_law("V4", fn _model, aggregates ->
        newest = aggregates.newest
        assert newest.balance_after == aggregates.row.balance
        assert newest.held_after == aggregates.row.held
        assert newest.promotional_after == aggregates.row.promotional
      end)
    end

    property "I10 no two rows of one kind share a reference" do
      check_law("V5", fn _model, aggregates ->
        assert aggregates.duplicate_references == []
      end)
    end
  end

  describe "integer bounds and rounding" do
    test "I10 a grant above the documented limit is refused at the facade, not by the driver (L17)" do
      # **The before and after of finding L17, in one test.** Until build unit
      # 06c nothing in `lib/` range checked an amount: the value travelled to
      # Postgres and came back as a `DBConnection.EncodeError` from Postgrex's
      # *encoder*, recorded on 2026-09-14 under Elixir 1.20.1 / OTP 29 /
      # Postgres 16.13. `Money.assert_range!/1` now refuses it at the facade.
      #
      # The limit is three orders of magnitude below the column's own, which is
      # why the ceiling grant below is refused as well: a figure a `bigint`
      # could hold is still not a figure this ledger will accept, because
      # `balance_after` and the conservation aggregate are sums of amounts.
      with_wallet(fn tenant ->
        error =
          catch_error(Credits.grant(tenant, @bigint_max, reference: tenant <> ":ceiling"))

        assert error.__struct__ == ArgumentError, inspect(error)
        assert Exception.message(error) =~ "outside the range AuroraMeter.Credits can hold"
        assert Exception.message(error) =~ "9000000000000000"

        # The largest amount the guard admits is admitted, so the test
        # distinguishes "refuses too much" from "refuses everything" (X155).
        assert {:ok, _txn} =
                 Credits.grant(tenant, Money.max_micro(), reference: tenant <> ":at-limit")

        assert Credits.balance(tenant).balance == Money.max_micro()
      end)
    end

    test "I10 a reversal above the documented limit is refused at the facade, not by the driver (L17)" do
      # The mirror case. `reverse/4` never refuses for want of balance, so
      # nothing in the ledger used to stand between a refund and the column's
      # lower bound either; the same guard now does, and it is symmetric.
      with_wallet(fn tenant ->
        error = catch_error(Credits.reverse(tenant, @bigint_max, tenant <> ":floor"))

        assert error.__struct__ == ArgumentError, inspect(error)
        assert Exception.message(error) =~ "outside the range AuroraMeter.Credits can hold"

        assert {:ok, _txn} = Credits.reverse(tenant, Money.max_micro(), tenant <> ":at-limit")
        assert Credits.balance(tenant).balance == -Money.max_micro()
      end)
    end

    test "I10 the range guard refuses before any database work (L17)" do
      # **The guard's claim is "before any I/O", so the way to test it is to
      # make any I/O fatal.** 01b's fault repo raises on every statement it is
      # armed for; an out-of-range amount must still come back as an
      # `ArgumentError` from the facade, which it can only do by never reaching
      # a statement.
      #
      # The second half is the control, and it is the half that makes the first
      # mean anything (X125). An in-range grant on the same wallet with the same
      # fault armed **does** hit the fault, so the wrapper is demonstrably on
      # the call path rather than bypassed, and `assert_fired!/1` holds the
      # harness rule that an armed fault is asserted to have fired.
      with_wallet(fn tenant ->
        Config.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
          Faults.arm(:before_commit, :raise, when: fn _context -> true end)

          error =
            catch_error(Credits.grant(tenant, Money.max_micro() + 1, reference: tenant <> ":io"))

          assert error.__struct__ == ArgumentError,
                 "assert_range!/1 reached a statement: #{inspect(error)}"

          assert Exception.message(error) =~ "outside the range AuroraMeter.Credits can hold"

          assert_raise Faults.Injected, fn ->
            Credits.grant(tenant, @dollar, reference: tenant <> ":io-control")
          end

          Faults.assert_fired!(:before_commit)
        end)
      end)
    end

    test "I10 cents round-trip through micro-dollars at the boundaries" do
      # `from_cents/1` is exact (`money.ex:57`), so the round trip is lossless
      # at every value a cent can take, the extremes included.
      for cents <- [0, 1, -1, 99, -99, 100, 12_345, -12_345, 9_007_199_254_740_992] do
        assert cents |> Money.from_cents() |> Money.to_cents() == cents
      end

      # Sub-cent micro-dollars are the unit's whole point, and they round rather
      # than round-trip.
      assert Money.to_cents(1) == 0
      assert Money.to_cents(999_999) == 100
      assert Money.to_cents(1_000_000) == 100
      assert Money.from_cents(1) == 10_000
    end

    test "I10 to_cents rounds half away from zero at the boundaries" do
      # `money.ex:211-212` states the rule; this pins it, in both directions,
      # rather than leaving it to be discovered by a display bug.
      assert Money.to_cents(5_000) == 1
      assert Money.to_cents(-5_000) == -1
      assert Money.to_cents(4_999) == 0
      assert Money.to_cents(-4_999) == 0
      assert Money.to_cents(15_000) == 2
      assert Money.to_cents(-15_000) == -2
      assert Money.to_cents(15_000, rounding: :floor) == 1
      assert Money.to_cents(15_000, rounding: :ceil) == 2
      assert Money.to_cents(-15_000, rounding: :floor) == -2
      assert Money.to_cents(-15_000, rounding: :ceil) == -1
    end
  end

  describe "ordering the query does not fix" do
    test "I10 two grants due in one pass expire in an order the query does not fix (L19, fixed in 06a)" do
      # `ledger.ex:251-259` selects the due grant ids with `repo.all/1` and no
      # `order_by`, while `expire_locked/3` (`:296-298`) clamps each grant by the
      # wallet as it stands when its turn comes. Two grants due in one pass can
      # therefore expire different amounts on two runs of the same history.
      # This test asserts the total and the conservation laws, and deliberately
      # does NOT assert the per-grant split: it enumerates both legal outcomes
      # instead. 06a must add the D07 order (earliest expires_at, then
      # inserted_at, then id) when the allocator replaces the replay.
      with_wallet(fn tenant ->
        {:ok, _} =
          Credits.grant(tenant, @dollar,
            reference: tenant <> ":a",
            category: :promotional,
            expires_at: @oct
          )

        {:ok, _} =
          Credits.grant(tenant, 2_000_000,
            reference: tenant <> ":b",
            category: :promotional,
            expires_at: @oct
          )

        {:ok, _} = Credits.hold(tenant, 2_000_000, tenant <> ":h")

        assert {:ok, 1} = Credits.expire_due(@dec)

        snapshot = Credits.balance(tenant)
        assert snapshot.balance == 2_000_000
        assert snapshot.held == 2_000_000
        assert snapshot.promotional == 2_000_000

        stamped =
          Enum.map(["a", "b"], fn suffix ->
            grant = grant_row(tenant, suffix)
            {suffix, not is_nil(grant.expired_at)}
          end)

        assert stamped in [
                 # "a" went first: it fit inside the spendable $1 exactly, so it
                 # is fully expired and "b" was refused with :held.
                 [{"a", true}, {"b", false}],
                 # "b" went first: it could only take $1 of its $2, so it is
                 # partially expired with no stamp, and "a" was then refused.
                 [{"a", false}, {"b", false}]
               ],
               "unexpected expiry split: #{inspect(stamped)}"
      end)
    end
  end

  describe "the clock the ledger orders itself by" do
    test "I10 a backwards step in the wall clock changes nothing, because the ledger orders by seq (L20, fixed in 06a)" do
      # `apply_entry/3` stamps `inserted_at` from `DateTime.utc_now()`
      # (`ledger.ex:452`) and then every query that has to know what happened
      # first orders by that column: `remaining_on_grant/3` (`:345`), which
      # decides how much of a promotional grant is left; `pending_holds/1`
      # (`:63`); `history/2` (finding L8). A wall clock is not monotonic, so the
      # ledger's account of its own order is only as good as the host's NTP.
      #
      # This is not hypothetical. The 500-run deep run at seed 20260914 on
      # 2026-09-14 abandoned three histories for exactly this: in tenant
      # model_35906 a grant written last carried
      # `~U[2026-09-14 09:53:18.928086Z]` while a grant written three commands
      # earlier carried `~U[2026-09-14 09:53:19.912292Z]`, a step of about 0.98
      # seconds backwards on a WSL2 host. The log is
      # `docs/evidence/v1/phase-01/logs/01e-deep.txt`.
      #
      # The property cannot assert on a clock step it cannot schedule, so this
      # test constructs the row state one produces (by moving a committed row's
      # timestamp, not by changing `lib/`) and drives the real code over it.
      with_wallet(fn tenant ->
        {:ok, grant} =
          Credits.grant(tenant, @dollar,
            reference: tenant <> ":promo",
            category: :promotional,
            expires_at: @oct
          )

        {:ok, _} = Credits.debit(tenant, 400_000, tenant <> ":spend")

        assert Credits.balance(tenant).promotional == 600_000
        assert ledger_remaining(tenant, grant.id) == 600_000

        # The clock steps back: the spend now claims to predate the grant that
        # funded it.
        move_inserted_at!(tenant, tenant <> ":spend", DateTime.add(grant.inserted_at, -1))

        # **This test changed in build unit 06a, and it changed because the
        # defect it proved is fixed.** It used to assert that the ledger now
        # believed the grant untouched (`== @dollar`), that expiry therefore
        # decided it was only partly expired, and that `expired_at` could never
        # afterwards be set. The row state it builds is deliberately unchanged:
        # the spend still carries a timestamp a second before its own grant's.
        #
        # **The negative control, and it is what carries the claim.** Folded in
        # the order the ledger used to use, the committed rows still produce the
        # inflated remainder, so the planted step is real and it is `seq` that
        # answers, not something else about these rows.
        assert fold_remaining(tenant, grant.id, :inserted_at) == @dollar
        assert ledger_remaining(tenant, grant.id) == 600_000
        assert Credits.balance(tenant).promotional == 600_000

        # And the financial consequence is gone with it: expiry compares $0.60
        # against a remainder of $0.60, decides the grant is fully expired and
        # stamps it, so the sweep does not reopen the same work for ever.
        Credits.expire_due(@dec)

        assert Credits.balance(tenant).balance == 0
        assert Credits.balance(tenant).promotional == 0
        refute is_nil(grant_row(tenant, "promo").expired_at)

        # A second pass finds nothing due: the grant is stamped, so it is out of
        # the candidate set rather than immortal inside it.
        assert {:ok, 0} = Credits.expire_due(@dec)
      end)
    end
  end

  # -- the lot view, no longer dormant ----------------------------------------
  #
  # `lot_view/1` was written by build unit 01e from `architecture-map.md`
  # section 7, **before 06a existed**, and 01e could only assert its internal
  # conservation because there were no lot tables to compare it with. There are
  # now. That makes it the thing G06 bullet 4 is really asking for and the thing
  # 06a's own generated-history property is not: a **second implementation** of
  # the same design, by a different unit, from the specification rather than
  # from the code. A systematic error in 06a's allocator is exactly what it can
  # catch and what comparing the database against itself cannot.

  property "I10 a generated history on a cut-over wallet agrees with 01e's independent lot model, lot for lot" do
    check all(
            history <- comparable_history(),
            max_runs: max(div(LedgerCommands.runs(), 2), 10)
          ) do
      compare_against_lot_view(history)
    end
  end

  # **The compared subset, and every exclusion is measured rather than assumed.**
  #
  # `:reverse` is dropped. With it in, **every** history diverged on three of
  # seven fixed seeds and the run compared nothing at all, which the teardown
  # below correctly turned into a failure: `Credits.reverse/4` takes the plain
  # debit path, so it disagrees with 01e's view of a lot reversal on the first
  # command that reaches it and the lockstep ends there. Dropping it leaves a
  # legal history (a reversal only removes value).
  #
  # **06e did not take this filter out, and X250 said it would.** The
  # correction is worth reading rather than quietly leaving the filter in
  # place. 06e adds `Credits.reverse_lot/4`, a *second* function scoped to a
  # payment's own lots, and deliberately leaves `Credits.reverse/4` wallet wide
  # for hosts with no payment provenance. So the command this generator issues
  # still takes the spend-order path and still disagrees with a model that
  # reverses paid lots only; what changed is that the disagreement is now a
  # documented difference between two public functions rather than a missing
  # implementation. Comparing the model against the lot-scoped path would need
  # the generator to mint payment ids, the model's grants to carry a `source`
  # and `reverse_from/3` to scope by it. That is real work on 01e's oracle, it
  # is recorded as its own finding in 06e's report, and inventing it here
  # inside 06e would make the oracle agree with the implementation by
  # construction, which is the one thing a second implementation must not do.
  #
  # `expiry: false` for a subtler reason, and it is the one worth reading.
  # 06a's deliberate compatibility change is that a lot past its `expires_at`
  # is not spendable before the sweep reaches it, while 01e's `live_lot?/1` is
  # `available > 0` with no expiry test. That shows up as a **refusal** only
  # when nothing else can pay; the ordinary case is that both sides accept the
  # debit and take it out of **different lots**, which a result-level
  # classifier cannot see at all. Comparing buckets across it would mean
  # encoding 06a's own spend decision into the oracle, which is the one thing a
  # second implementation must not do.
  defp comparable_history do
    StreamData.map(
      LedgerCommands.history(expiry: false),
      &Enum.reject(&1, fn command -> match?({:reverse, _reference, _amount}, command) end)
    )
  end

  # The third exclusion, and it is decided from the model rather than from the
  # generator. A settlement above its hold creates `debt`, and from then on
  # 06a's planner repays it out of anything a release hands back while 01e's
  # view does not, so the two part company on buckets without ever disagreeing
  # on a result. `overrun?` is the model's own record of that having happened.
  defp debt_reachable?(model) do
    model
    |> LedgerModel.closed_holds()
    |> Enum.any?(fn {_reference, hold} -> hold.overrun? end)
  end

  test "I10 the cross-oracle comparison can fail: a lot bucket moved by hand is caught" do
    # **The negative control for the property above** (finding X125). The
    # property passes by comparing two implementations, and it would pass just
    # as happily if the comparison itself were vacuous, which is the failure
    # mode X242 describes. One micro-dollar is moved between two buckets of a
    # committed lot, which no ledger operation would do and which the lot's own
    # CHECK constraint permits because the sum is unchanged; the comparison must
    # notice.
    with_wallet(fn tenant ->
      Ledger.enable_lots!(tenant)

      history = [
        {:grant, "g1", @dollar, :paid, nil},
        {:debit, "d1", 400_000}
      ]

      {model, divergences} = drive(tenant, history)
      assert divergences == []
      assert :compared = compare_lots(tenant, LedgerModel.lot_view(model))

      Connections.repo().query!(
        "UPDATE aurora_meter_credit_lots SET available = available - 1, consumed = consumed + 1 " <>
          "WHERE tenant_key = $1",
        [tenant]
      )

      assert_raise ExUnit.AssertionError, fn ->
        compare_lots(tenant, LedgerModel.lot_view(model))
      end
    end)
  end

  # -- helpers ----------------------------------------------------------------

  # The four named conservation properties run shorter histories at a fifth of
  # the run count: every one of V1 to V6 is already asserted after every step by
  # the executor, and these exist so a failure says which law broke.
  defp check_law(label, assertion) do
    check all(
            history <- LedgerCommands.history(length: {5, 15}),
            max_runs: max(div(LedgerCommands.runs(), 5), 5)
          ) do
      result = LedgerCommands.run(history, seed: seed(), label: label, cleanup: false)

      try do
        # An abandoned history (the wall clock stepped backwards mid-run, L20)
        # is evidence of nothing either way. It is counted and reported by
        # `report_clock_steps/0`, never quietly treated as a pass.
        if not Map.has_key?(result, :inconclusive) do
          check_one(result.model, LedgerCommands.aggregates(result.tenant), assertion)
        end
      after
        Connections.cleanup!(result.tenant)
      end
    end
  end

  # A history can consist entirely of refusals: a hold against an empty wallet,
  # an `expire_due` with nothing due, a repeated reference. Not one of them
  # writes an entry, so there is no newest row and no aggregate to compare; what
  # the law becomes in that case is that the model wrote nothing either. This is
  # a real shape the generator produces, not a corner to skip: the shrinker found
  # `[{:hold, "h1", 1}, {:expire_due, _}, {:expire_due, _}, {:expire_due, _},
  # {:hold, "h5", 1}]` on 2026-09-14.
  defp check_one(model, aggregates, assertion) do
    if model.entries == [] do
      assert aggregates.newest == nil
      assert aggregates.amount_sum == 0
      assert aggregates.held_delta_sum == 0
    else
      assertion.(model, aggregates)
    end
  end

  defp report_clock_steps do
    case LedgerCommands.clock_steps() do
      [] ->
        :ok

      steps ->
        IO.puts("""

        #{length(steps)} generated history/histories were abandoned as inconclusive: the wall \
        clock the ledger stamps `inserted_at` from stepped backwards mid-run. Since build unit \
        06a the ledger no longer ORDERS by that column (it orders by `seq`), so a step no longer \
        makes the ledger misreport a remainder; what it still does is make this harness's own \
        `inserted_at` comparisons meaningless, which is why the history is abandoned rather than \
        failed. The properties above therefore covered #{length(steps)} fewer histories than \
        they asked for.

        #{Enum.map_join(steps, "\n", &"  #{&1.tenant} step #{&1.step}: #{inspect(&1.stamps)}")}
        """)
    end
  end

  # -- the cross-oracle comparison --------------------------------------------

  defp compare_against_lot_view(history) do
    with_wallet(fn tenant ->
      Ledger.enable_lots!(tenant)
      {model, divergences} = drive(tenant, history)
      view = LedgerModel.lot_view(model)

      # The model's own conservation, which 01e asserted alone.
      assert LedgerModel.v8_problems(view) == [],
             "01e's lot view does not conserve: #{inspect(LedgerModel.v8_problems(view))}"

      # And the database's, independently.
      assert_database_conserves(tenant)

      cond do
        divergences == [] and not debt_reachable?(model) ->
          assert :compared = compare_lots(tenant, view)
          record_comparison(:compared)

        # Debt was reachable in this history, so the buckets are allowed to part
        # company (`:debt_repaid_on_release`). Both sides still have to
        # conserve, which is asserted above, and the model's own V8 check has
        # already run.
        divergences == [] ->
          record_comparison(:diverged)

        true ->
          assert_classified!(divergences)
          record_comparison(:diverged)
      end
    end)
  end

  # Every divergence has to be one 06a has written down. An unclassified one is
  # the whole point of a second oracle and fails here rather than being
  # absorbed into a widened list.
  defp assert_classified!(divergences) do
    for {command, expected, actual, class} <- divergences do
      assert class in [:eligibility, :reverse_not_wired, :debt_repaid_on_release],
             "unclassified divergence on #{inspect(command)}: the model said " <>
               "#{inspect(expected)} and the ledger said #{inspect(actual)}. " <>
               "Two implementations of one design disagree in a way 06a has not " <>
               "written down, which is what this property exists to find."
    end

    :ok
  end

  # Runs one history against the real ledger and against the model in lockstep,
  # classifying every result disagreement **until the first one**.
  #
  # After a divergence the two states are different, so every later
  # disagreement is a consequence rather than a finding: a hold the ledger
  # refused makes the settle that follows it `:not_found` here and `:ok` there,
  # which says nothing about the allocator. The first run of this property
  # reported exactly that cascade as an unclassified divergence, which would
  # have been a false alarm for a reader and, worse, would have trained the next
  # one to widen the classification until it caught nothing.
  defp drive(tenant, history) do
    Enum.reduce(history, {LedgerModel.new(), []}, fn command, {model, diverged} ->
      {next, expected} = LedgerModel.apply(model, command)
      actual = execute(tenant, command)
      {next, step_divergence(diverged, command, expected, actual)}
    end)
  end

  defp step_divergence([_first | _rest] = diverged, _command, _expected, _actual), do: diverged

  defp step_divergence([], command, expected, actual) do
    case classify(command, expected, actual) do
      :agree -> []
      :skip -> []
      class -> [{command, expected, actual, class}]
    end
  end

  defp execute(tenant, {:grant, reference, amount, category, expires_at}) do
    Credits.grant_with_status(tenant, amount,
      reference: scoped(tenant, reference),
      category: category,
      expires_at: expires_at
    )
  end

  defp execute(tenant, {:hold, reference, amount}),
    do: Credits.hold(tenant, amount, scoped(tenant, reference))

  defp execute(tenant, {:settle, reference, actual}),
    do: Credits.settle(scoped(tenant, reference), actual)

  defp execute(tenant, {:release, reference}), do: Credits.release(scoped(tenant, reference))

  defp execute(tenant, {:debit, reference, amount}),
    do: Credits.debit(tenant, amount, scoped(tenant, reference))

  defp execute(tenant, {:reverse, reference, amount}),
    do: Credits.reverse(tenant, amount, scoped(tenant, reference))

  defp execute(_tenant, {:expire_due, now}), do: Credits.expire_due(now)

  defp scoped(tenant, reference), do: tenant <> ":" <> reference

  # `:reverse` is compared for nothing, and the reason is a real gap rather than
  # a convenience. `Credits.reverse/4` calls `debit/5` with
  # `allow_negative: true`, so on a cut-over wallet it consumes eligible lots in
  # spend order, **promotional first**, and writes nothing into `reversed`.
  # 01e's view models the lot design instead: paid lots only, buckets in the
  # order available, consumed, reserved. From 06e the lot design is reachable,
  # but through `Credits.reverse_lot/4` and not through this command, and the
  # wallet-wide function keeps its behaviour on purpose. See the note on
  # `comparable_history/0`. Recorded as X250 and corrected in 06e's report.
  defp classify({:reverse, _reference, _amount}, _expected, _actual), do: :reverse_not_wired

  # `expire_due/1` returns a count across **every** tenant in the database, so
  # its number is not this wallet's and comparing it would be comparing the
  # suite. The resulting lot state is compared like any other.
  defp classify({:expire_due, _now}, _expected, _actual), do: :skip

  # **The third divergence, and 06a's deliberate choice against 01e's view.**
  # 01e's `replay/3` for a release unreserves and subtracts `held` and stops;
  # 06a's planner then repays outstanding debt out of what came back, because
  # LI-06a-5 says `debt > 0` implies no availability, and because a wallet
  # frozen for spending while holding money it owes is worse for the tenant than
  # one that pays itself off. `architecture-map.md` 7.2 says "every incoming
  # **grant** repays outstanding debt first" and should say "every incoming
  # value" (finding X251).
  defp classify({:release, _reference}, :ok, {:ok, _txn}), do: :agree

  defp classify(_command, expected, actual) do
    cond do
      same?(expected, actual) -> :agree
      # 06a's one deliberate compatibility change: a lot past its `expires_at`
      # is not spendable before the sweep reaches it, and 01e's `live_lot?/1`
      # is `available > 0` with no expiry test. The ledger refusing something
      # the model accepted is that, and only that.
      match?({:error, :insufficient_credits}, actual) -> :eligibility
      true -> :unclassified
    end
  end

  defp same?(:ok, {:ok, _txn}), do: true
  defp same?({:ok, status}, {:ok, _txn, status}), do: true
  defp same?({:error, reason}, {:error, reason}), do: true
  defp same?(_expected, _actual), do: false

  # Lot for lot, by the grant reference both sides key on, every bucket exact.
  defp compare_lots(tenant, view) do
    import Ecto.Query, only: [from: 2]

    rows =
      Connections.repo().all(
        from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: [asc: l.seq])
      )

    modelled = Map.new(view.lots, fn lot -> {lot.reference, lot} end)
    actual = Map.new(rows, fn row -> {unscope(tenant, row.reference), row} end)

    assert Map.keys(modelled) |> Enum.sort() == Map.keys(actual) |> Enum.sort(),
           "the two implementations disagree about which lots exist: model " <>
             "#{inspect(Enum.sort(Map.keys(modelled)))} against database " <>
             "#{inspect(Enum.sort(Map.keys(actual)))}"

    for {reference, lot} <- modelled do
      row = Map.fetch!(actual, reference)

      for bucket <- [:available, :reserved, :consumed, :reversed, :expired] do
        assert Map.fetch!(lot, bucket) == Map.fetch!(row, bucket),
               "lot #{reference} #{bucket}: 01e's model says #{Map.fetch!(lot, bucket)} and " <>
                 "06a's ledger says #{Map.fetch!(row, bucket)}"
      end

      assert lot.amount == row.amount
      assert lot.category == row.category
    end

    # And the wallet, which the view tracks independently of its own buckets.
    row = Connections.repo().get_by!(CreditBalance, tenant_key: tenant)
    assert view.balance == row.balance
    assert view.held == row.held
    assert view.promotional == row.promotional
    assert view.expired == row.expired
    assert view.debt == row.debt

    :compared
  end

  defp unscope(tenant, reference), do: String.replace_prefix(reference, tenant <> ":", "")

  defp assert_database_conserves(tenant) do
    import Ecto.Query, only: [from: 2]

    repo = Connections.repo()
    row = repo.get_by!(CreditBalance, tenant_key: tenant)
    lots = repo.all(from(l in CreditLot, where: l.tenant_key == ^tenant))

    available = Enum.reduce(lots, 0, &(&1.available + &2))
    reserved = Enum.reduce(lots, 0, &(&1.reserved + &2))
    expired = Enum.reduce(lots, 0, &(&1.expired + &2))

    assert row.balance == available + reserved - row.debt
    assert row.held == reserved
    assert row.expired == expired

    for lot <- lots do
      assert lot.available + lot.reserved + lot.consumed + lot.reversed + lot.expired ==
               lot.amount
    end

    # No allocation may name a lot that is not this wallet's.
    orphans =
      repo.all(
        from(a in CreditAllocation,
          where: a.tenant_key == ^tenant,
          where: a.lot_id not in ^Enum.map(lots, & &1.id),
          select: a.id
        )
      )

    assert orphans == [], "allocations naming a lot outside the wallet: #{inspect(orphans)}"
  end

  # **Counted, and asserted on an ordinary run** (finding X214). A property that
  # diverged on every history would compare nothing and still be green, which is
  # exactly the shape X182 describes.
  defp record_comparison(outcome) do
    key = {__MODULE__, :cross_oracle}
    counts = :persistent_term.get(key, %{compared: 0, diverged: 0})
    :persistent_term.put(key, Map.update!(counts, outcome, &(&1 + 1)))
    :ok
  end

  defp cross_oracle_counts,
    do: :persistent_term.get({__MODULE__, :cross_oracle}, %{compared: 0, diverged: 0})

  defp with_wallet(fun) do
    Connections.checkout!()
    tenant = AuroraMeter.Test.unique_tenant("model")

    try do
      fun.(tenant)
    after
      Connections.cleanup!(tenant)
    end
  end

  defp grant_row(tenant, suffix) do
    import Ecto.Query, only: [from: 2]

    Connections.repo().one!(
      from(t in CreditTransaction,
        where:
          t.tenant_key == ^tenant and t.kind == ^:grant and
            t.reference == ^(tenant <> ":" <> suffix)
      )
    )
  end

  # `Ledger.remaining_on_grant/3` reproduced exactly, with `repo.all` for
  # `repo.stream` because this is not inside a transaction. The order is the
  # ledger's own, which since schema version 9 is `seq`.
  defp ledger_remaining(tenant, grant_id), do: fold_remaining(tenant, grant_id, :seq)

  # The same fold with the ordering column as an argument, so a test can put the
  # old order beside the new one on the same committed rows.
  defp fold_remaining(tenant, grant_id, order) do
    import Ecto.Query, only: [from: 2]

    Connections.repo().all(
      from(t in CreditTransaction,
        where:
          t.tenant_key == ^tenant and
            (t.amount < 0 or (t.kind == ^:grant and t.category == ^:promotional)),
        order_by: ^[asc: order]
      )
    )
    |> Promotions.remaining(grant_id)
  end

  # Moves one committed row's `inserted_at`, which is the only way to schedule
  # the backwards clock step the deep run observed. It writes no `lib/` code and
  # produces a row state the ledger demonstrably produces on its own.
  defp move_inserted_at!(tenant, reference, at) do
    import Ecto.Query, only: [from: 2]

    {1, _} =
      Connections.repo().update_all(
        from(t in CreditTransaction,
          where: t.tenant_key == ^tenant and t.reference == ^reference
        ),
        set: [inserted_at: at]
      )

    :ok
  end

  defp seed, do: ExUnit.configuration()[:seed]

  defp play(commands), do: replay(LedgerModel.new(), commands)

  defp replay(model, commands) do
    Enum.reduce(commands, model, fn command, acc ->
      {next, _result} = LedgerModel.apply(acc, command)
      next
    end)
  end
end
