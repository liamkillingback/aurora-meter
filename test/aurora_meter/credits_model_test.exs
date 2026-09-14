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
  alias AuroraMeter.Credits.Money
  alias AuroraMeter.Credits.Promotions
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Connections
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

    test "model: a hold and a debit share no reference namespace, but a debit and a reversal do (L2)" do
      model = play([{:grant, "g1", @dollar, :paid, nil}])

      {model, held} = LedgerModel.apply(model, {:hold, "x", 100_000})
      {model, debited} = LedgerModel.apply(model, {:debit, "x", 100_000})
      {model, reversed} = LedgerModel.apply(model, {:reverse, "x", 1})

      assert held == :ok
      assert debited == :ok
      # credits.ex:329-335 sends reverse/4 through Ledger.debit/5, so it lands
      # in the `:debit` half of the (kind, reference) index. Finding L2, 06c.
      assert reversed == {:error, :duplicate_reference}
      assert model.balance == 900_000
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
    test "I10 a grant at the bigint ceiling is refused by the database (L17, fixed in 06c)" do
      # There is no overflow guard anywhere in `lib/` (finding L17): the value
      # travels to Postgres and the driver refuses it. Recorded here so 06c can
      # replace this behaviour with `Money.assert_range!/1` at the facade and
      # flip the assertion to an ArgumentError with a readable message.
      with_wallet(fn tenant ->
        assert {:ok, _txn} = Credits.grant(tenant, @bigint_max, reference: tenant <> ":ceiling")

        error = catch_error(Credits.grant(tenant, 1, reference: tenant <> ":over"))

        # Recorded on 2026-09-14, Elixir 1.20.1 / OTP 29 / Postgres 16.13: the
        # refusal comes from Postgrex's *encoder*, before any statement is sent,
        # so it is a DBConnection.EncodeError rather than a Postgres
        # numeric_value_out_of_range. 06c replaces it with
        # `Money.assert_range!/1` at the facade and this assertion flips to an
        # ArgumentError naming the amount.
        assert error.__struct__ == DBConnection.EncodeError, inspect(error)

        assert Exception.message(error) =~
                 "Postgrex expected an integer in -9223372036854775808..9223372036854775807"

        # The wallet is untouched: the ledger's transaction rolled back.
        assert Credits.balance(tenant).balance == @bigint_max
      end)
    end

    test "I10 a reversal at the bigint floor is refused by the database (L17, fixed in 06c)" do
      # The mirror case. `reverse/4` never refuses for want of balance
      # (`ledger.ex:222`), so nothing in the ledger stands between a refund and
      # the column's lower bound either.
      with_wallet(fn tenant ->
        assert {:ok, _txn} = Credits.reverse(tenant, @bigint_max, tenant <> ":floor")
        assert Credits.balance(tenant).balance == -@bigint_max

        error = catch_error(Credits.reverse(tenant, 2, tenant <> ":under"))

        assert error.__struct__ == DBConnection.EncodeError, inspect(error)

        assert Exception.message(error) =~
                 "Postgrex expected an integer in -9223372036854775808..9223372036854775807"

        assert Credits.balance(tenant).balance == -@bigint_max
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
    test "I10 a backwards step in the wall clock leaves a promotional grant that can never expire (L20, fixed in 06a)" do
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

        # The ledger now believes the grant is untouched, although $0.40 of it
        # is spent and the wallet says so.
        assert ledger_remaining(tenant, grant.id) == @dollar
        assert Credits.balance(tenant).promotional == 600_000

        # The financial consequence. Expiry takes min(remaining, promotional,
        # spendable) = $0.60 and, because it compares that against a remainder
        # inflated to $1.00, decides the grant is only partly expired
        # (`ledger.ex:299`) and leaves `expired_at` unset.
        Credits.expire_due(@dec)

        assert Credits.balance(tenant).balance == 0
        assert Credits.balance(tenant).promotional == 0
        assert is_nil(grant_row(tenant, "promo").expired_at)

        # And it can never be set: every later pass finds nothing spendable and
        # a remainder that is still not zero, so it refuses with `:held`
        # (`ledger.ex:304-305`) for ever. The grant is immortal, and
        # `expire_due/1` reopens the same work on every run.
        Credits.expire_due(@dec)

        assert Credits.balance(tenant).balance == 0
        assert is_nil(grant_row(tenant, "promo").expired_at)
      end)
    end
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
        clock the ledger stamps `inserted_at` from (`ledger.ex:452`) stepped backwards mid-run, \
        so the ledger's own `(inserted_at, id)` order stopped being the order it wrote in. That \
        is finding L20, proved on its own by \
        `test I10 a backwards step in the wall clock leaves a promotional grant that can never \
        expire (L20, fixed in 06a)`. The properties above therefore covered #{length(steps)} \
        fewer histories than they asked for.

        #{Enum.map_join(steps, "\n", &"  #{&1.tenant} step #{&1.step}: #{inspect(&1.stamps)}")}
        """)
    end
  end

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

  # `Ledger.remaining_on_grant/3` (`ledger.ex:340-349`) reproduced exactly, with
  # `repo.all` for `repo.stream` because this is not inside a transaction. The
  # order is the ledger's own: `(inserted_at, id)`.
  defp ledger_remaining(tenant, grant_id) do
    import Ecto.Query, only: [from: 2]

    Connections.repo().all(
      from(t in CreditTransaction,
        where:
          t.tenant_key == ^tenant and
            (t.amount < 0 or (t.kind == ^:grant and t.category == ^:promotional)),
        order_by: [asc: t.inserted_at, asc: t.id]
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
