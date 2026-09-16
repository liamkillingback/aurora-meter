defmodule AuroraMeter.CreditsTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: true
  use ExUnitProperties

  import AuroraMeter.Test, only: [fund!: 2, fund!: 3, drain!: 1, credit_balance: 1]

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Money
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.LedgerFixtures

  doctest AuroraMeter.Credits
  doctest AuroraMeter.Credits.Money
  doctest AuroraMeter.Schema.CreditTransaction

  @dollar 1_000_000

  @doc false
  def handle_event(event, measurements, metadata, %{parent: parent, tenant: tenant}) do
    if metadata.tenant_key == tenant,
      do: send(parent, {:telemetry, event, measurements, metadata})

    :ok
  end

  defp attach(events, tenant) do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, %{
        parent: self(),
        tenant: tenant
      })

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "grant/3" do
    test "credits the balance and is idempotent per reference" do
      tenant = unique_tenant()

      assert {:ok, %CreditTransaction{kind: :grant, category: :paid, amount: 20_000_000} = txn} =
               Credits.grant(tenant, 20 * @dollar, reference: "pi_1")

      assert {:ok, ^txn} = Credits.grant(tenant, 20 * @dollar, reference: "pi_1")
      assert Credits.balance(tenant).balance == 20 * @dollar
      assert [%{id: id}] = Credits.history(tenant)
      assert id == txn.id
    end

    test "a duplicate grant reports duplicate: true in telemetry and does not broadcast" do
      tenant = unique_tenant()
      attach([[:aurora_meter, :credits, :grant]], tenant)
      :ok = Credits.subscribe(tenant)

      {:ok, _} = Credits.grant(tenant, @dollar, reference: "pi_dup")

      assert_receive {:telemetry, _, %{amount: 1_000_000},
                      %{duplicate: false, reference: "pi_dup"}}

      assert_receive {:aurora_meter, :credits, %{balance: 1_000_000, available: 1_000_000}}

      {:ok, _} = Credits.grant(tenant, @dollar, reference: "pi_dup")
      assert_receive {:telemetry, _, %{amount: 0, balance_after: 1_000_000}, %{duplicate: true}}
      refute_receive {:aurora_meter, :credits, _}
    end

    test "requires a reference and rejects expiry on non-promotional grants" do
      tenant = unique_tenant()
      assert_raise KeyError, fn -> Credits.grant(tenant, @dollar, []) end

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Credits.grant(tenant, @dollar, reference: "x", expires_at: DateTime.utc_now())

      assert {"only promotional grants expire", _} = errors[:expires_at]
      assert Credits.balance(tenant).balance == 0
    end

    test "balance/1 is all zeros for an unknown tenant and reflects every field after" do
      tenant = unique_tenant()

      assert %{balance: 0, held: 0, available: 0, promotional: 0, currency: "usd"} =
               Credits.balance(tenant)

      fund!(tenant, 3 * @dollar)
      fund!(tenant, @dollar, category: :promotional)
      {:ok, _} = Credits.hold(tenant, @dollar, "h:#{tenant}")

      assert %{balance: 4_000_000, held: 1_000_000, available: 3_000_000, promotional: 1_000_000} =
               Credits.balance(tenant)

      assert Credits.available(tenant) == 3_000_000
      assert Credits.sufficient?(tenant, 3_000_000)
      refute Credits.sufficient?(tenant, 3_000_001)
    end
  end

  describe "hold/4, settle/3, release/1" do
    test "a hold is refused when the available balance does not cover it" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)
      assert {:ok, _} = Credits.hold(tenant, 600_000, "a:#{tenant}")
      assert {:error, :insufficient_credits} = Credits.hold(tenant, 600_000, "b:#{tenant}")
      assert {:error, :duplicate_reference} = Credits.hold(tenant, 100_000, "a:#{tenant}")
      assert %{held: 600_000, available: 400_000} = Credits.balance(tenant)
    end

    test "settling below the hold charges the actual amount and frees the whole hold" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)
      {:ok, _} = Credits.hold(tenant, 500_000, "job:#{tenant}")

      assert {:ok, %CreditTransaction{kind: :settle, amount: -420_000, settled_amount: 420_000}} =
               Credits.settle("job:#{tenant}", 420_000)

      assert %{balance: 580_000, held: 0, available: 580_000} = Credits.balance(tenant)

      assert %CreditTransaction{status: :settled, settled_amount: 420_000} =
               hold_for("job:#{tenant}")

      assert {:error, :already_settled} = Credits.settle("job:#{tenant}", 1)
      assert {:error, :already_settled} = Credits.release("job:#{tenant}")
    end

    test "settling above the hold never fails, may go negative, and reports the overrun" do
      tenant = unique_tenant()
      attach([[:aurora_meter, :credits, :settle]], tenant)
      fund!(tenant, @dollar)
      {:ok, _} = Credits.hold(tenant, 800_000, "job:#{tenant}")

      assert {:ok, %CreditTransaction{balance_after: -200_000, held_after: 0}} =
               Credits.settle("job:#{tenant}", 1_200_000)

      assert %{balance: -200_000, held: 0, available: -200_000} = Credits.balance(tenant)

      assert_receive {:telemetry, [:aurora_meter, :credits, :settle], %{amount: -1_200_000},
                      %{overrun: true}}

      refute Credits.sufficient?(tenant, 1)
    end

    test "release drops the hold without charging" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)
      {:ok, _} = Credits.hold(tenant, 500_000, "job:#{tenant}")

      assert {:ok, %CreditTransaction{kind: :release, amount: 0, held_delta: -500_000}} =
               Credits.release("job:#{tenant}")

      assert %{balance: 1_000_000, held: 0} = Credits.balance(tenant)
      assert %CreditTransaction{status: :released} = hold_for("job:#{tenant}")
      assert {:error, :already_settled} = Credits.settle("job:#{tenant}", 1)
      assert {:error, :not_found} = Credits.release("nope:#{tenant}")
      assert {:error, :not_found} = Credits.settle("nope:#{tenant}", 1)
    end
  end

  describe "debit/4" do
    test "charges immediately with the same rules as a hold" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)

      assert {:ok, %CreditTransaction{kind: :debit, amount: -250_000, metadata: %{"m" => 1}}} =
               Credits.debit(tenant, 250_000, "d:#{tenant}", %{"m" => 1})

      assert {:error, :duplicate_reference} = Credits.debit(tenant, 1, "d:#{tenant}")
      assert {:error, :insufficient_credits} = Credits.debit(tenant, 750_001, "e:#{tenant}")
      assert {:ok, _} = Credits.debit(tenant, 750_000, "e:#{tenant}")
      assert %{balance: 0, available: 0} = Credits.balance(tenant)
    end
  end

  describe "with_credits/4" do
    test "settles on {:ok, result, actual}" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)

      assert {:ok, :done} =
               Credits.with_credits(tenant, 500_000, "w:#{tenant}", fn ->
                 {:ok, :done, 300_000}
               end)

      assert %{balance: 700_000, held: 0} = Credits.balance(tenant)
    end

    test "releases on {:error, reason} and returns it" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)

      assert {:error, :boom} =
               Credits.with_credits(tenant, 500_000, "w:#{tenant}", fn -> {:error, :boom} end)

      assert %{balance: 1_000_000, held: 0} = Credits.balance(tenant)
      assert %CreditTransaction{status: :released} = hold_for("w:#{tenant}")
    end

    test "releases when the function raises, throws or exits, then propagates" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)

      assert_raise RuntimeError, "boom", fn ->
        Credits.with_credits(tenant, 500_000, "raise:#{tenant}", fn -> raise "boom" end)
      end

      assert catch_throw(
               Credits.with_credits(tenant, 500_000, "throw:#{tenant}", fn -> throw(:ball) end)
             ) == :ball

      assert catch_exit(
               Credits.with_credits(tenant, 500_000, "exit:#{tenant}", fn -> exit(:bye) end)
             ) == :bye

      assert %{balance: 1_000_000, held: 0} = Credits.balance(tenant)

      for ref <- ~w(raise throw exit),
          do: assert(%{status: :released} = hold_for("#{ref}:#{tenant}"))
    end

    test "does not run the function when the hold is refused" do
      tenant = unique_tenant()

      assert {:error, :insufficient_credits} =
               Credits.with_credits(tenant, 1, "w:#{tenant}", fn -> flunk("ran") end)
    end

    test "an unexpected return releases the hold and raises" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)

      assert_raise ArgumentError, ~r/expects/, fn ->
        Credits.with_credits(tenant, 500_000, "w:#{tenant}", fn -> :nope end)
      end

      assert %{held: 0} = Credits.balance(tenant)
    end

    test "I11 returns its result when the hold was settled by someone else" do
      # L4. The success branch used to be `{:ok, _txn} = settle(reference,
      # actual)`, which raises a MatchError the moment anything else closes the
      # hold while the work runs. Nothing could, until this unit shipped a
      # reconciler that can. The raise was then caught by the `catch` below it,
      # which released again and re-raised, so the caller got a MatchError
      # instead of its result and the executed work was never charged.
      tenant = unique_tenant()
      fund!(tenant, @dollar)
      reference = "settled_by_other:#{tenant}"

      assert {:ok, :done} =
               Credits.with_credits(tenant, 500_000, reference, fn ->
                 # Somebody else settles first: a reconciler's {:settle, n}
                 # decision, or a duplicate delivery of the same job.
                 {:ok, _} = Credits.settle(reference, 300_000)
                 {:ok, :done, 300_000}
               end)

      assert %CreditTransaction{status: :settled, settled_amount: 300_000} = hold_for(reference)
      assert length(entries(tenant, :settle)) == 1
      assert %{balance: 700_000, held: 0} = Credits.balance(tenant)
    end

    test "I11 records the executed cost when the hold was released by someone else" do
      # L4, the half that loses money. The reservation was handed back, but the
      # work ran and cost something, so the cost is recorded as its own debit
      # under `settle_missed:<reference>` rather than dropped.
      tenant = unique_tenant()
      fund!(tenant, @dollar)
      reference = "released_by_other:#{tenant}"

      assert {:ok, :done} =
               Credits.with_credits(tenant, 500_000, reference, fn ->
                 {:ok, _} = Credits.release(reference)
                 {:ok, :done, 300_000}
               end)

      assert %CreditTransaction{status: :released} = hold_for(reference)
      assert [] == entries(tenant, :settle)
      assert [%CreditTransaction{amount: -300_000}] = entries(tenant, :debit)

      assert %CreditTransaction{reference: "settle_missed:" <> ^reference} =
               hd(entries(tenant, :debit))

      assert %{balance: 700_000, held: 0} = Credits.balance(tenant)
    end

    test "writes nothing extra when the released hold's actual cost was zero" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)
      reference = "released_zero:#{tenant}"

      assert {:ok, :done} =
               Credits.with_credits(tenant, 500_000, reference, fn ->
                 {:ok, _} = Credits.release(reference)
                 {:ok, :done, 0}
               end)

      assert entries(tenant, :debit) == []
      assert %{balance: 1_000_000, held: 0} = Credits.balance(tenant)
    end

    test "is idempotent for the settle_missed debit across a retry" do
      tenant = unique_tenant()
      fund!(tenant, @dollar)
      reference = "retried:#{tenant}"

      run = fn ->
        Credits.with_credits(tenant, 500_000, reference, fn ->
          {:ok, _} = Credits.release(reference)
          {:ok, :done, 300_000}
        end)
      end

      assert {:ok, :done} = run.()
      # The second call is refused at the hold: the reference is already used.
      assert {:error, :duplicate_reference} = run.()

      assert length(entries(tenant, :debit)) == 1
      assert %{balance: 700_000} = Credits.balance(tenant)
    end
  end

  describe "history/2" do
    test "is newest first, hides holds and releases by default, filters by kind and pages" do
      tenant = unique_tenant()
      fund!(tenant, @dollar, reference: "g1")
      {:ok, _} = Credits.hold(tenant, 100_000, "h1:#{tenant}")
      {:ok, _} = Credits.settle("h1:#{tenant}", 90_000)
      {:ok, _} = Credits.hold(tenant, 100_000, "h2:#{tenant}")
      {:ok, _} = Credits.release("h2:#{tenant}")
      {:ok, _} = Credits.debit(tenant, 50_000, "d1:#{tenant}")

      assert [:debit, :settle, :grant] = tenant |> Credits.history() |> Enum.map(& &1.kind)

      assert [:release, :hold, :hold] =
               tenant |> Credits.history(kinds: [:hold, :release]) |> Enum.map(& &1.kind)

      assert [%{kind: :debit} = newest] = Credits.history(tenant, limit: 1)

      assert [:settle, :grant] =
               tenant |> Credits.history(before: newest.inserted_at) |> Enum.map(& &1.kind)

      assert [:grant] =
               tenant
               |> Credits.history(before: newest.inserted_at, limit: 1, kinds: [:grant])
               |> Enum.map(& &1.kind)
    end
  end

  describe "reverse/4" do
    test "takes the money back without consuming promotional credit" do
      # A refund of a paid top-up used to eat the trial grant: `promotional`
      # fell to zero, so `expire_due/1` had nothing left to reclaim and the
      # grant stayed live for ever.
      tenant = unique_tenant()
      fund!(tenant, 500_000, category: :promotional)
      fund!(tenant, @dollar, category: :paid)
      assert %{balance: 1_500_000, promotional: 500_000} = Credits.balance(tenant)

      assert {:ok, txn} = Credits.reverse(tenant, 400_000, "refund:#{tenant}")
      assert txn.category == :reversal

      assert %{balance: 1_100_000, promotional: 500_000} = Credits.balance(tenant)
    end

    test "still cannot push promotional above the balance" do
      # Legacy: the flat ledger clamped `promotional` down with the balance.
      # On the allocator the promotion is kept whole and the shortfall becomes
      # `debt` instead (`credits_lot_reversal_test.exs` / X250).
      tenant = LedgerFixtures.legacy_wallet!(unique_tenant())
      fund!(tenant, 500_000, category: :promotional)
      fund!(tenant, 100_000, category: :paid)

      # Only 400_000 of balance is left, so the promotional figure has to come
      # down with it — the invariant outranks protecting the bonus.
      assert {:ok, _} = Credits.reverse(tenant, 200_000, "refund:#{tenant}")
      assert %{balance: 400_000, promotional: 400_000} = Credits.balance(tenant)
    end

    test "is idempotent on its reference and may go negative" do
      tenant = unique_tenant()
      fund!(tenant, 100_000, category: :paid)

      assert {:ok, _} = Credits.reverse(tenant, 300_000, "refund:#{tenant}")
      assert %{balance: -200_000} = Credits.balance(tenant)
      assert {:error, :duplicate_reference} = Credits.reverse(tenant, 300_000, "refund:#{tenant}")
      assert %{balance: -200_000} = Credits.balance(tenant)
    end
  end

  describe "the ledger as a record" do
    test "every entry says what the promotional figure became" do
      # `balance` and `held` were always reconstructible from the log; the
      # promotional figure was not. It is consumed before paid credit and
      # clamped to the balance after every entry, so it moves for reasons no
      # `amount` explains - and with no snapshot the balance row was the only
      # copy of it, with nothing to tell a clamp from a bug.
      tenant = unique_tenant()
      fund!(tenant, 500_000, category: :promotional)
      fund!(tenant, @dollar, category: :paid)
      {:ok, _} = Credits.debit(tenant, 200_000, "spend:#{tenant}")
      {:ok, _} = Credits.reverse(tenant, 1_200_000, "refund:#{tenant}")

      assert %{promotional: promotional} = Credits.balance(tenant)

      assert [%CreditTransaction{promotional_after: ^promotional} | _rest] =
               Credits.history(tenant)

      for txn <- Credits.history(tenant) do
        assert is_integer(txn.promotional_after), "#{txn.kind} left no promotional snapshot"
      end
    end
  end

  describe "promotional credit" do
    test "is consumed before paid credit" do
      tenant = unique_tenant()
      fund!(tenant, @dollar, category: :paid)
      fund!(tenant, 300_000, category: :promotional)
      assert %{balance: 1_300_000, promotional: 300_000} = Credits.balance(tenant)

      {:ok, _} = Credits.debit(tenant, 200_000, "d1:#{tenant}")
      assert %{balance: 1_100_000, promotional: 100_000} = Credits.balance(tenant)

      {:ok, _} = Credits.hold(tenant, 500_000, "h1:#{tenant}")
      {:ok, _} = Credits.settle("h1:#{tenant}", 400_000)
      assert %{balance: 700_000, promotional: 0} = Credits.balance(tenant)
    end

    test "expire_due/1 expires only what is left, once, and never below zero" do
      tenant = LedgerFixtures.legacy_wallet!(unique_tenant())
      attach([[:aurora_meter, :credits, :expire]], tenant)
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      future = DateTime.add(DateTime.utc_now(), 3_600, :second)

      fund!(tenant, 200_000, category: :paid)
      grant = fund!(tenant, 500_000, category: :promotional, expires_at: past, reference: "promo")
      {:ok, _} = Credits.debit(tenant, 300_000, "used:#{tenant}")
      assert %{balance: 400_000, promotional: 200_000} = Credits.balance(tenant)

      later = unique_tenant()
      fund!(later, 100_000, category: :promotional, expires_at: future)

      assert {:ok, n} = Credits.expire_due()
      assert n >= 1

      assert %{balance: 200_000, promotional: 0} = Credits.balance(tenant)
      assert %{balance: 100_000, promotional: 100_000} = Credits.balance(later)

      assert %CreditTransaction{expired_at: %DateTime{}} =
               TestRepo.get!(CreditTransaction, grant.id)

      assert [%CreditTransaction{kind: :expire, amount: -200_000, reference: "expire:" <> id}] =
               Credits.history(tenant, kinds: [:expire])

      assert id == grant.id
      assert_receive {:telemetry, [:aurora_meter, :credits, :expire], %{amount: -200_000}, _}

      # Already expired: nothing more happens to this tenant.
      {:ok, _} = Credits.expire_due()
      assert %{balance: 200_000} = Credits.balance(tenant)
      assert length(Credits.history(tenant, kinds: [:expire])) == 1
    end

    test "I12 expiry never claws back credit a hold has reserved" do
      # hold/4 promises the money will be there when the work settles. Expiry
      # used to walk straight through that: it took the balance below `held`,
      # and the settle that followed took the balance itself negative — a debt
      # the tenant silently repays out of their next top-up.
      tenant = LedgerFixtures.legacy_wallet!(unique_tenant())
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      grant = fund!(tenant, 500_000, category: :promotional, expires_at: past)
      {:ok, _} = Credits.hold(tenant, 400_000, "work:#{tenant}")

      assert {:ok, _} = Credits.expire_due()

      # Only the unheld 100_000 could go.
      balance = Credits.balance(tenant)
      assert balance.held == 400_000
      assert balance.available == 0
      assert balance.balance == 400_000

      # The grant is not finished with, so it is still due next time.
      assert %CreditTransaction{expired_at: nil} = TestRepo.get!(CreditTransaction, grant.id)

      # Settling does not drive the balance negative.
      {:ok, _} = Credits.settle("work:#{tenant}", 400_000)
      assert %{balance: 0, held: 0} = Credits.balance(tenant)

      # With the hold gone, the rest of the grant finally expires.
      assert {:ok, _} = Credits.expire_due()
      assert %{balance: 0, promotional: 0} = Credits.balance(tenant)

      assert %CreditTransaction{expired_at: %DateTime{}} =
               TestRepo.get!(CreditTransaction, grant.id)
    end

    test "I12 a grant expires only its own remainder" do
      # `promotional` on the balance is the sum of every live grant, so
      # expiring against that total let the first grant to expire reclaim
      # money the second had contributed.
      tenant = LedgerFixtures.legacy_wallet!(unique_tenant())
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      future = DateTime.add(DateTime.utc_now(), 3_600, :second)

      soon = fund!(tenant, 500_000, category: :promotional, expires_at: past)
      _later = fund!(tenant, 1_000_000, category: :promotional, expires_at: future)

      # Spend more than the expiring grant was worth: it is used up, and what
      # is left belongs to the grant that has not expired.
      {:ok, _} = Credits.debit(tenant, 1_200_000, "used:#{tenant}")
      assert %{balance: 300_000, promotional: 300_000} = Credits.balance(tenant)

      assert {:ok, _} = Credits.expire_due()

      # The expiring grant had nothing left, so the survivor keeps its money.
      assert %{balance: 300_000, promotional: 300_000} = Credits.balance(tenant)

      assert %CreditTransaction{expired_at: %DateTime{}} =
               TestRepo.get!(CreditTransaction, soon.id)
    end

    test "I12 a new expiring grant cannot absorb spending that predates it" do
      tenant = unique_tenant()
      fund!(tenant, 500_000, category: :promotional)
      {:ok, _} = Credits.debit(tenant, 500_000, "spent-before-new-grant:#{tenant}")

      fund!(tenant, 500_000,
        category: :promotional,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
      )

      assert {:ok, _} = Credits.expire_due()
      assert %{balance: 0, promotional: 0} = Credits.balance(tenant)
    end

    test "I12 a release after the grant expired returns spendable credit (L1, fixed in 06a)" do
      # L1, the mirror of the test above. Expiry leaves alone what a hold has
      # reserved, which is right; what it cannot do is remember. When the hold
      # is released the value goes back to the balance as ordinary spendable
      # credit, although the grant it came from expired an hour ago, and it
      # stays spendable until some scheduler happens to run expire_due/1 again.
      tenant = LedgerFixtures.legacy_wallet!(unique_tenant())
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      fund!(tenant, 500_000, category: :promotional, expires_at: past)
      {:ok, _} = Credits.hold(tenant, 400_000, "work:#{tenant}")

      assert {:ok, _} = Credits.expire_due()
      assert %{balance: 400_000, held: 400_000, available: 0} = Credits.balance(tenant)

      assert {:ok, _} = Credits.release("work:#{tenant}")

      # Spendable, not expired. 06a's lot model makes the released value expired.
      assert %{balance: 400_000, held: 0, available: 400_000} = Credits.balance(tenant)
      assert {:ok, _} = Credits.debit(tenant, 400_000, "after-expiry:#{tenant}")
      assert %{balance: 0, promotional: 0} = Credits.balance(tenant)
    end

    test "a promotional grant landing on a negative balance first repays the debt" do
      tenant = unique_tenant()
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      fund!(tenant, 100_000)
      {:ok, _} = Credits.hold(tenant, 100_000, "h:#{tenant}")
      {:ok, _} = Credits.settle("h:#{tenant}", 400_000)
      assert %{balance: -300_000, promotional: 0} = Credits.balance(tenant)

      fund!(tenant, 500_000, category: :promotional, expires_at: past)
      assert %{balance: 200_000, promotional: 200_000} = Credits.balance(tenant)

      {:ok, _} = Credits.expire_due()
      assert %{balance: 0, promotional: 0} = Credits.balance(tenant)
    end
  end

  describe "low balance" do
    test "fires telemetry and PubSub once per crossing of the tenant's threshold" do
      tenant = unique_tenant()
      attach([[:aurora_meter, :credits, :low_balance]], tenant)
      :ok = Credits.subscribe(tenant)
      fund!(tenant, @dollar)

      assert {:ok, %{low_balance_threshold: 500_000}} =
               Credits.set_low_balance_threshold(tenant, 500_000)

      assert Credits.balance(tenant).low_balance_threshold == 500_000

      {:ok, _} = Credits.debit(tenant, 400_000, "d1:#{tenant}")
      refute_receive {:telemetry, [:aurora_meter, :credits, :low_balance], _, _}

      {:ok, _} = Credits.hold(tenant, 200_000, "h1:#{tenant}")

      assert_receive {:telemetry, [:aurora_meter, :credits, :low_balance],
                      %{available: 400_000, threshold: 500_000}, %{tenant_key: ^tenant}}

      assert_receive {:aurora_meter, :low_balance,
                      %{tenant_key: ^tenant, available: 400_000, threshold: 500_000}}

      # Still below: quiet.
      {:ok, _} = Credits.settle("h1:#{tenant}", 250_000)
      refute_receive {:telemetry, [:aurora_meter, :credits, :low_balance], _, _}
      refute_receive {:aurora_meter, :low_balance, _}

      # Recover above, cross again: fires again.
      fund!(tenant, 300_000)
      {:ok, _} = Credits.debit(tenant, 200_000, "d2:#{tenant}")

      assert_receive {:telemetry, [:aurora_meter, :credits, :low_balance], %{available: 450_000},
                      _}

      assert_receive {:aurora_meter, :low_balance, %{available: 450_000}}

      assert {:ok, %{low_balance_threshold: nil}} = Credits.set_low_balance_threshold(tenant, nil)
    end
  end

  describe "test helpers" do
    test "fund!/3, drain!/1 and credit_balance/1" do
      tenant = unique_tenant()

      assert %CreditTransaction{category: :adjustment, amount: 2_500_000} =
               fund!(tenant, 2_500_000)

      assert %CreditTransaction{category: :paid} = fund!(tenant, 1, category: :paid)
      assert credit_balance(tenant).available == 2_500_001
      assert drain!(tenant) == 2_500_001
      assert credit_balance(tenant).available == 0
      assert drain!(tenant) == 0
    end
  end

  describe "Money" do
    property "cents round-trip through micro-dollars" do
      check all(cents <- integer()) do
        micro = Money.from_cents(cents)
        assert Money.to_cents(micro) == cents
        assert Money.to_cents(micro, rounding: :floor) == cents
        assert Money.to_cents(micro, rounding: :ceil) == cents
        assert Money.from_decimal(Decimal.div(Decimal.new(cents), 100)) == micro
      end
    end

    property "format/2 prints whole cents exactly" do
      check all(cents <- integer()) do
        dollars = div(abs(cents), 100)
        rest = rem(abs(cents), 100) |> Integer.to_string() |> String.pad_leading(2, "0")
        sign = if cents < 0, do: "-", else: ""
        assert Money.format(Money.from_cents(cents)) == "#{sign}$#{dollars}.#{rest}"
      end
    end

    test "rounding modes and precision" do
      assert Money.to_cents(15_000) == 2
      assert Money.to_cents(14_999) == 1
      assert Money.to_cents(-15_000) == -2
      assert Money.to_cents(10_001, rounding: :ceil) == 2
      assert Money.to_cents(19_999, rounding: :floor) == 1
      assert Money.to_cents(-10_001, rounding: :floor) == -2
      assert Money.to_cents(-19_999, rounding: :ceil) == -1
      assert Money.format(-4_999) == "$0.00"
      assert Money.format(-5_000) == "-$0.01"
      assert Money.format(1_234_567, precision: 4) == "$1.2346"
      assert Money.format(123, precision: 6) == "$0.000123"
      assert Money.from_decimal(Decimal.new("0.0000005")) == 1
    end
  end

  # -- the compatibility surface (build unit 06c, V1 task 06.03) --------------
  #
  # Deliberately at module level rather than inside a `describe`: an invariant
  # test's description has to start with its id (finding X196), and a `describe`
  # prefixes it.

  test "I10 a reverse and a debit may share one reference (L2)" do
    # A host keys its charge by the order id and Pro keys the refund by the same
    # order id. Until build unit 06c both landed in the `:debit` half of the
    # `(kind, reference)` unique index, so the second was told
    # `:duplicate_reference` for a write it had never made and the refund was
    # silently not applied.
    tenant = unique_tenant()
    fund!(tenant, 10 * @dollar)

    assert {:ok, debit} = Credits.debit(tenant, @dollar, "order:99")
    assert {:ok, reversal} = Credits.reverse(tenant, 2 * @dollar, "order:99")

    assert debit.kind == :debit
    assert debit.reference == "order:99"
    assert reversal.kind == :reverse
    assert reversal.reference == "order:99"
    assert reversal.category == :reversal
    assert debit.id != reversal.id

    assert Credits.balance(tenant).balance == 7 * @dollar

    # Idempotency inside each namespace is unchanged, which is the half a
    # "they no longer collide" change could quietly lose.
    assert {:error, :duplicate_reference} = Credits.debit(tenant, @dollar, "order:99")
    assert {:error, :duplicate_reference} = Credits.reverse(tenant, @dollar, "order:99")
    assert Credits.balance(tenant).balance == 7 * @dollar
  end

  test "I10 a reversal written before V9 still reads as a reversal" do
    # Rows already in the log keep `kind: :debit, category: :reversal` for ever.
    # `reversal?/1` is the one predicate that knows both shapes, and the
    # reporting that matters scores by `category`, so a legacy row reports
    # exactly as a new one does.
    tenant = unique_tenant()
    fund!(tenant, 10 * @dollar)
    {:ok, reversal} = Credits.reverse(tenant, 2 * @dollar, "refund:#{tenant}")

    new_shape = Credits.spend_total(tenant, days: 1)

    {1, _} =
      TestRepo.update_all(
        from(t in CreditTransaction, where: t.id == ^reversal.id),
        set: [kind: :debit]
      )

    legacy = TestRepo.get!(CreditTransaction, reversal.id)
    assert legacy.kind == :debit
    assert legacy.category == :reversal
    assert CreditTransaction.reversal?(legacy)
    assert CreditTransaction.reversal?(reversal)

    # A reversal scores against grants rather than as spend, in both shapes, so
    # `spend_history/2` and `spend_total/2` are byte identical across the
    # change. This is the assertion that fails if anything in `Series` had been
    # switched from `category` to `kind`.
    assert Credits.spend_total(tenant, days: 1) == new_shape
    assert Credits.spend_total(tenant, days: 1).spent == 0
    assert Credits.spend_total(tenant, days: 1).granted == 8 * @dollar
  end

  test "I10 a grant whose reference belongs to another tenant returns duplicate_reference (L3)" do
    # The in-transaction lookup is scoped to this tenant, so a reference another
    # tenant already used is invisible to it and the insert hits the **global**
    # unique index. `hold/4` and `debit/4` have always answered that with
    # `:duplicate_reference`; `grant/3` answered with a raw changeset, which is
    # a different shape for the same fact.
    first = unique_tenant()
    second = unique_tenant()

    assert {:ok, _} = Credits.grant(first, @dollar, reference: "shared:ref")

    assert {:error, :duplicate_reference} =
             Credits.grant(second, @dollar, reference: "shared:ref")

    assert {:error, :duplicate_reference} =
             Credits.grant_with_status(second, @dollar, reference: "shared:ref")

    # Nothing was credited to the second tenant, and the first is untouched.
    assert Credits.balance(second).balance == 0
    assert Credits.balance(first).balance == @dollar

    # Same tenant, same reference is still the original entry rather than an
    # error: that is the idempotency contract and it is unchanged.
    assert {:ok, _txn, :duplicate} =
             Credits.grant_with_status(first, @dollar, reference: "shared:ref")
  end

  test "I10 a grant whose changeset fails for another reason still returns the changeset" do
    # The mapping above is narrow on purpose. A grant can produce exactly one
    # other changeset error, and a caller needs to see the field and the message
    # rather than a `:duplicate_reference` that would send it looking for a
    # collision that is not there.
    tenant = unique_tenant()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Credits.grant(tenant, @dollar,
               reference: "paid-with-expiry:#{tenant}",
               expires_at: ~U[2030-01-01 00:00:00Z]
             )

    assert {"only promotional grants expire", _} = changeset.errors[:expires_at]
    assert Credits.balance(tenant).balance == 0
  end

  test "I10 spend_history rejects :reverse as a spend kind" do
    tenant = unique_tenant()

    assert_raise ArgumentError, ~r/reported against grants/, fn ->
      Credits.spend_history(tenant, kinds: [:reverse])
    end

    assert_raise ArgumentError, ~r/reported against grants/, fn ->
      Credits.spend_total(tenant, kinds: [:settle, :reverse])
    end

    # The message style matches the one `:grant` already used, and the two
    # existing refusals are untouched.
    assert_raise ArgumentError, ~r/scores it twice/, fn ->
      Credits.spend_history(tenant, kinds: [:grant])
    end

    assert_raise ArgumentError, ~r/never spend/, fn ->
      Credits.spend_history(tenant, kinds: [:hold])
    end
  end

  defp hold_for(reference), do: Ledger.fetch_hold(reference)

  defp entries(tenant, kind) do
    TestRepo.all(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant and t.kind == ^kind,
        order_by: [asc: t.inserted_at]
      )
    )
  end
end
