defmodule AuroraMeter.CreditsSeriesTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: true

  import AuroraMeter.Test, only: [fund!: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Money
  alias AuroraMeter.Schema.CreditTransaction

  @dollar 1_000_000

  # Backdates a ledger entry so the series can be exercised across days and
  # months without waiting for time to pass. It writes the transaction row the
  # series reads; the balance row is maintained by the real API in the tests
  # that also assert on balances.
  defp backdate!(tenant, kind, amount, date, opts \\ []) do
    TestRepo.insert!(%CreditTransaction{
      tenant_key: tenant,
      kind: kind,
      category: Keyword.get(opts, :category),
      amount: amount,
      held_delta: Keyword.get(opts, :held_delta, 0),
      balance_after: Keyword.get(opts, :balance_after, 0),
      held_after: Keyword.get(opts, :held_after, 0),
      reference: "backdate:#{System.unique_integer([:positive])}",
      inserted_at: at(date, Keyword.get(opts, :hour, 12))
    })
  end

  defp at(date, hour) do
    date |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC") |> DateTime.add(0, :microsecond)
  end

  defp on(points, date), do: Enum.find(points, &(&1.date == date))

  describe "spend_history/2" do
    test "zero-fills every bucket in the range, oldest first" do
      tenant = unique_tenant()
      today = Date.utc_today()
      backdate!(tenant, :debit, -@dollar, Date.add(today, -4), balance_after: 9 * @dollar)
      backdate!(tenant, :debit, -2 * @dollar, today, balance_after: 7 * @dollar)

      points = Credits.spend_history(tenant, days: 5)

      assert length(points) == 5
      assert Enum.map(points, & &1.date) == Enum.to_list(Date.range(Date.add(today, -4), today))

      # The three-day gap in the middle is present and explicitly zero — not
      # missing, which is what a chart would have to paper over.
      assert Enum.map(points, & &1.spent) == [@dollar, 0, 0, 0, 2 * @dollar]
      assert Enum.map(points, & &1.granted) == [0, 0, 0, 0, 0]
      assert Enum.map(points, & &1.net) == [-@dollar, 0, 0, 0, -2 * @dollar]
    end

    test "a tenant with no ledger at all still gets a full, zero-filled range" do
      points = Credits.spend_history(unique_tenant(), days: 7)

      assert length(points) == 7
      assert Enum.all?(points, &(&1.spent == 0 and &1.granted == 0 and &1.net == 0))
      assert Enum.all?(points, &is_nil(&1.balance_after))
    end

    test "balance_after is the last entry in the bucket, and nil for an empty bucket" do
      tenant = unique_tenant()
      today = Date.utc_today()
      yesterday = Date.add(today, -1)

      backdate!(tenant, :debit, -@dollar, yesterday, balance_after: 9 * @dollar, hour: 1)
      backdate!(tenant, :debit, -@dollar, yesterday, balance_after: 8 * @dollar, hour: 23)

      points = Credits.spend_history(tenant, days: 2)

      assert on(points, yesterday).balance_after == 8 * @dollar
      assert on(points, yesterday).spent == 2 * @dollar
      assert on(points, today).balance_after == nil
    end

    test "holds and releases are excluded — they move `held`, not `balance`" do
      tenant = unique_tenant()
      fund!(tenant, 10 * @dollar)
      {:ok, _} = Credits.hold(tenant, 3 * @dollar, "job:hold_only")
      {:ok, _} = Credits.hold(tenant, 2 * @dollar, "job:released")
      {:ok, _} = Credits.release("job:released")
      {:ok, _} = Credits.settle("job:hold_only", @dollar)

      [today] = Credits.spend_history(tenant, days: 1)

      # $1 settled. Not $3 (the hold), not $6 (hold + release + settle).
      assert today.spent == @dollar
      assert today.granted == 10 * @dollar
      assert today.net == 9 * @dollar
      assert Credits.balance(tenant).balance == 9 * @dollar
    end

    test "an expiry counts as spend" do
      tenant = unique_tenant()
      today = Date.utc_today()
      backdate!(tenant, :expire, -5 * @dollar, today, category: :promotional)

      [point] = Credits.spend_history(tenant, days: 1)

      assert point.spent == 5 * @dollar
      assert point.net == -5 * @dollar
    end

    test "grants are reported separately from spend" do
      tenant = unique_tenant()
      today = Date.utc_today()

      backdate!(tenant, :grant, 20 * @dollar, today,
        category: :paid,
        balance_after: 20 * @dollar,
        hour: 9
      )

      backdate!(tenant, :debit, -3 * @dollar, today, balance_after: 17 * @dollar, hour: 10)

      [point] = Credits.spend_history(tenant, days: 1)

      assert point.granted == 20 * @dollar
      assert point.spent == 3 * @dollar
      assert point.net == 17 * @dollar
      assert point.balance_after == 17 * @dollar
    end

    test "a reversal is taken off grants, not counted as spend" do
      # A refund is money handed back, not money used. Counting it as spend
      # told a refunded customer they had spent it, and inflated the burn rate
      # the runway estimate divides by.
      tenant = unique_tenant()
      today = Date.utc_today()

      backdate!(tenant, :grant, 20 * @dollar, today,
        category: :paid,
        balance_after: 20 * @dollar,
        hour: 9
      )

      backdate!(tenant, :debit, -3 * @dollar, today, balance_after: 17 * @dollar, hour: 10)

      backdate!(tenant, :debit, -8 * @dollar, today,
        category: :reversal,
        balance_after: 9 * @dollar,
        hour: 11
      )

      [point] = Credits.spend_history(tenant, days: 1)

      assert point.spent == 3 * @dollar
      assert point.granted == 12 * @dollar
      assert point.net == 9 * @dollar
      assert point.balance_after == 9 * @dollar

      assert %{spent: spent, granted: granted} = Credits.spend_total(tenant, days: 1)
      assert spent == 3 * @dollar
      assert granted == 12 * @dollar
    end

    test "bucket: :month groups by UTC month and zero-fills the months between" do
      tenant = unique_tenant()
      to = ~D[2026-09-11]

      backdate!(tenant, :debit, -@dollar, ~D[2026-07-03], balance_after: 9 * @dollar)
      backdate!(tenant, :debit, -2 * @dollar, ~D[2026-07-28], balance_after: 7 * @dollar)
      backdate!(tenant, :grant, 5 * @dollar, ~D[2026-09-02], balance_after: 12 * @dollar)

      points = Credits.spend_history(tenant, bucket: :month, from: ~D[2026-07-01], to: to)

      assert Enum.map(points, & &1.date) == [~D[2026-07-01], ~D[2026-08-01], ~D[2026-09-01]]
      assert Enum.map(points, & &1.spent) == [3 * @dollar, 0, 0]
      assert Enum.map(points, & &1.granted) == [0, 0, 5 * @dollar]
      assert Enum.map(points, & &1.balance_after) == [7 * @dollar, nil, 12 * @dollar]
    end

    test "buckets are UTC days, not local days" do
      tenant = unique_tenant()
      date = ~D[2026-06-15]
      backdate!(tenant, :debit, -@dollar, date, hour: 0)
      backdate!(tenant, :debit, -@dollar, date, hour: 23)

      points = Credits.spend_history(tenant, from: date, to: Date.add(date, 1))

      assert Enum.map(points, & &1.spent) == [2 * @dollar, 0]
    end

    test "entries outside the range are excluded at both ends" do
      tenant = unique_tenant()
      backdate!(tenant, :debit, -@dollar, ~D[2026-05-31])
      backdate!(tenant, :debit, -2 * @dollar, ~D[2026-06-01])
      backdate!(tenant, :debit, -4 * @dollar, ~D[2026-06-02])
      backdate!(tenant, :debit, -8 * @dollar, ~D[2026-06-03])

      points = Credits.spend_history(tenant, from: ~D[2026-06-01], to: ~D[2026-06-02])

      assert Enum.map(points, & &1.spent) == [2 * @dollar, 4 * @dollar]
    end

    test ":kinds narrows what counts as spend" do
      tenant = unique_tenant()
      today = Date.utc_today()
      backdate!(tenant, :debit, -@dollar, today)
      backdate!(tenant, :expire, -5 * @dollar, today, category: :promotional)

      assert [%{spent: spent}] = Credits.spend_history(tenant, days: 1, kinds: [:settle, :debit])
      assert spent == @dollar
    end

    test ":kinds rejects holds and releases, which move no money" do
      tenant = unique_tenant()

      assert_raise ArgumentError, ~r/holds and releases move `held`/, fn ->
        Credits.spend_history(tenant, kinds: [:debit, :hold])
      end
    end

    test "an invalid bucket or an inverted range raises" do
      tenant = unique_tenant()

      assert_raise ArgumentError, ~r/:bucket must be :day or :month/, fn ->
        Credits.spend_history(tenant, bucket: :week)
      end

      assert_raise ArgumentError, ~r/is after/, fn ->
        Credits.spend_history(tenant, from: ~D[2026-06-02], to: ~D[2026-06-01])
      end
    end

    test "two tenants' ledgers never bleed into each other" do
      mine = unique_tenant()
      theirs = unique_tenant()
      today = Date.utc_today()
      backdate!(mine, :debit, -@dollar, today)
      backdate!(theirs, :debit, -99 * @dollar, today)

      assert [%{spent: spent}] = Credits.spend_history(mine, days: 1)
      assert spent == @dollar
    end
  end

  describe "spend_total/2" do
    test "sums the range and reports the range it used" do
      tenant = unique_tenant()
      today = Date.utc_today()
      backdate!(tenant, :grant, 20 * @dollar, Date.add(today, -2), category: :paid)
      backdate!(tenant, :debit, -3 * @dollar, Date.add(today, -1))
      backdate!(tenant, :debit, -@dollar, today)

      total = Credits.spend_total(tenant, days: 3)

      assert total.spent == 4 * @dollar
      assert total.granted == 20 * @dollar
      assert total.net == 16 * @dollar
      assert total.from == Date.add(today, -2)
      assert total.to == today
    end

    test "an untouched tenant totals to zero, not nil" do
      total = Credits.spend_total(unique_tenant(), days: 3)

      assert total.spent == 0
      assert total.granted == 0
      assert total.net == 0
    end

    test "agrees with the sum of spend_history/2 over the same range" do
      tenant = unique_tenant()
      today = Date.utc_today()
      backdate!(tenant, :debit, -@dollar, Date.add(today, -5))
      backdate!(tenant, :settle, -2 * @dollar, Date.add(today, -1))

      points = Credits.spend_history(tenant, days: 7)
      total = Credits.spend_total(tenant, days: 7)

      assert Enum.reduce(points, 0, &(&1.spent + &2)) == total.spent
      assert Enum.reduce(points, 0, &(&1.granted + &2)) == total.granted
    end
  end

  describe "summary/1" do
    test "carries the balance, this period's movement, and burn and runway" do
      tenant = unique_tenant()
      fund!(tenant, 300 * @dollar)
      {:ok, _} = Credits.debit(tenant, 30 * @dollar, "spend:1")

      summary = Credits.summary(tenant)

      assert summary.balance == 270 * @dollar
      assert summary.available == 270 * @dollar
      assert summary.held == 0
      assert summary.promotional == 0
      assert summary.currency == "usd"
      assert summary.spent_this_period == 30 * @dollar
      assert summary.granted_this_period == 300 * @dollar
      assert %DateTime{} = summary.period.start
      assert %DateTime{} = summary.period.end

      # $30 over the trailing 30 days is $1/day, and $270 available is 270 days.
      assert summary.daily_burn == @dollar
      assert summary.runway_days == 270
    end

    test "a tenant that has never spent has nil burn and nil runway" do
      tenant = unique_tenant()
      fund!(tenant, 50 * @dollar)

      summary = Credits.summary(tenant)

      assert summary.balance == 50 * @dollar
      assert summary.spent_this_period == 0
      assert summary.daily_burn == nil
      assert summary.runway_days == nil
    end

    test "spend too small to average a micro-dollar a day gives zero burn and nil runway" do
      tenant = unique_tenant()
      fund!(tenant, 50 * @dollar)
      {:ok, _} = Credits.debit(tenant, 10, "dust")

      summary = Credits.summary(tenant)

      assert summary.daily_burn == 0
      assert summary.runway_days == nil
    end

    test "an overdrawn balance has zero runway, never a negative one" do
      tenant = unique_tenant()
      fund!(tenant, 30 * @dollar)
      {:ok, _} = Credits.hold(tenant, 30 * @dollar, "overrun:1")
      {:ok, _} = Credits.settle("overrun:1", 60 * @dollar)

      summary = Credits.summary(tenant)

      assert summary.available == -30 * @dollar
      assert summary.daily_burn == 2 * @dollar
      assert summary.runway_days == 0
    end

    test "held credit is reported and excluded from `available`" do
      tenant = unique_tenant()
      fund!(tenant, 10 * @dollar)
      {:ok, _} = Credits.hold(tenant, 4 * @dollar, "pending:1")

      summary = Credits.summary(tenant)

      assert summary.held == 4 * @dollar
      assert summary.available == 6 * @dollar
      assert summary.balance == 10 * @dollar
      # The hold itself is not spend.
      assert summary.spent_this_period == 0
    end

    test "only this period counts towards spent_this_period" do
      tenant = unique_tenant()
      period = AuroraMeter.period(tenant)
      before_period = period.start |> DateTime.add(-1, :day) |> DateTime.to_date()

      fund!(tenant, 100 * @dollar)
      {:ok, _} = Credits.debit(tenant, 2 * @dollar, "this_period")
      backdate!(tenant, :debit, -50 * @dollar, before_period)

      assert Credits.summary(tenant).spent_this_period == 2 * @dollar
    end
  end

  describe "Money.format_compact/1" do
    test "collapses large amounts and keeps small ones honest" do
      assert Money.format_compact(0) == "$0"
      assert Money.format_compact(70_000) == "$0.07"
      assert Money.format_compact(12_350_000) == "$12.35"
      assert Money.format_compact(999_940_000) == "$999.94"
      assert Money.format_compact(1_234_000_000) == "$1.2k"
      assert Money.format_compact(2_000_000_000) == "$2k"
      assert Money.format_compact(1_500_000_000_000) == "$1.5M"
      assert Money.format_compact(-4_500_000_000_000) == "-$4.5M"
      assert Money.format_compact(1_500_000_000_000_000) == "$1.5B"
    end

    test "never rounds a sub-cent amount away to $0.00" do
      assert Money.format_compact(15) == "$0.000015"
      assert Money.format_compact(400) == "$0.0004"
      assert Money.format_compact(-400) == "-$0.0004"
    end

    test "never emits a thousand of the smaller unit" do
      # $999.95 rounds up to a full "$1k" rather than rendering as "$1000".
      assert Money.format_compact(999_950_000) == "$1k"
      # $999,999 likewise promotes to "$1M" instead of "$1000k".
      assert Money.format_compact(999_999_000_000) == "$1M"
    end
  end
end
