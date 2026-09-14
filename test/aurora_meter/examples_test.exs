defmodule Bramble.Plans do
  @moduledoc "The plans module printed in docs/examples/team-saas.md, verbatim."
  use AuroraMeter.Plans

  plan :free do
    price 0
    feature :seats, 3
    feature :pdf_export, false
    feature :audit_log, false
    limit :projects, 2, :hard
    limit :file_uploads, 100, :hard
  end

  plan :team do
    price 4_900
    feature :seats, 20
    feature :pdf_export, true
    feature :audit_log, false
    limit :projects, 50, :hard
    limit :file_uploads, 10_000, :hard
  end

  plan :business do
    price 19_900
    feature :seats, 200
    feature :pdf_export, true
    feature :audit_log, true
    limit :projects, 1_000, :hard
    limit :file_uploads, 250_000, :hard
  end
end

defmodule Inkwell.Plans do
  @moduledoc "The plans module printed in docs/examples/allowance-and-overage.md."
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :generations, 25, :hard
  end

  plan :writer do
    price 2_900
    metered :generations, included: 1_000, unit_price: 2
  end

  plan :studio do
    price 9_900
    metered :generations, included: 5_000, unit_price: 1
  end
end

defmodule Parsely.Plans do
  @moduledoc "The plans module printed in docs/examples/prepaid-credits.md."
  use AuroraMeter.Plans

  plan :payg do
    price 0
    counter :pages_parsed
    counter :api_requests
    feature :webhooks, true
  end
end

defmodule Lumen.Plans do
  @moduledoc "The plans module printed in docs/examples/events-source.md."
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :tokens, 100_000, :hard
  end

  plan :studio do
    price 9_900
    metered :tokens, included: 2_000_000, unit_price: 1
  end
end

defmodule Lumen.Model do
  @moduledoc """
  The guide's `Lumen.Model` is the host's own model client, so it is the one
  thing in that example this suite has to supply rather than copy. Its shape is
  fixed by what `Lumen.Gateway.complete/2` below reads off the response, and
  that function IS copied verbatim.
  """

  @spec run(String.t()) :: map()
  def run(prompt) do
    %{
      text: "answer to " <> prompt,
      tokens: 1_420,
      request_id: "req_" <> Integer.to_string(System.unique_integer([:positive])),
      finished_at: AuroraMeter.Clock.now(),
      model: "sonnet"
    }
  end
end

defmodule Lumen.Gateway do
  @moduledoc "Gate on an estimate, charge for what actually happened."

  @estimate 4_000

  def complete(org, prompt) do
    AuroraMeter.with_quota(org, :tokens, @estimate, fn ->
      response = Lumen.Model.run(prompt)

      {:ok, event, _outcome} =
        AuroraMeter.record(org, :tokens, response.tokens,
          id: response.request_id,
          occurred_at: response.finished_at,
          dimensions: %{"model" => response.model}
        )

      %{text: response.text, tokens: event.quantity}
    end)
  end
end

defmodule MyApp.DailyPeriod do
  @moduledoc "Usage buckets to the UTC day."

  @behaviour AuroraMeter.Period

  @impl AuroraMeter.Period
  def current(_tenant, now), do: day(DateTime.to_date(now))

  @impl AuroraMeter.Period
  def containing(_tenant, instant), do: day(DateTime.to_date(instant))

  defp day(date) do
    %{
      start: DateTime.new!(date, ~T[00:00:00], "Etc/UTC"),
      end: DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC"),
      source: :daily
    }
  end
end

defmodule MyApp.WeeklyPeriod do
  @moduledoc "Usage buckets to the ISO week: Monday 00:00:00 UTC to Monday 00:00:00 UTC."

  @behaviour AuroraMeter.Period

  @impl AuroraMeter.Period
  def current(_tenant, now), do: week(DateTime.to_date(now))

  @impl AuroraMeter.Period
  def containing(_tenant, instant), do: week(DateTime.to_date(instant))

  defp week(date) do
    monday = Date.beginning_of_week(date, :monday)

    %{
      start: DateTime.new!(monday, ~T[00:00:00], "Etc/UTC"),
      end: DateTime.new!(Date.add(monday, 7), ~T[00:00:00], "Etc/UTC"),
      source: :weekly
    }
  end
end

defmodule AuroraMeter.ExamplesTest do
  @moduledoc """
  The example guides, executed.

  Documentation drifts silently: a guide is not compiled, not run, and nothing
  fails when the function it describes changes. Everything asserted here is a
  claim made in `docs/examples/`, with the same numbers, so a guide that stops
  being true stops the suite instead.

  The plan modules above are the guides' own, copied verbatim — compiling them
  is itself a test, since the DSL validates at compile time.
  """
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test, only: [with_clock: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Money
  alias AuroraMeter.Period
  alias AuroraMeter.Test.Config, as: TestConfig

  describe "concepts.md" do
    test "micro-dollars are what the table says they are" do
      assert Money.from_cents(2_500) == 25_000_000
      assert Money.to_cents(1_500_000) == 150
      assert Money.format(1_500_000) == "$1.50"

      # The guides warn about this: format/2 is two decimal places by default,
      # so a sub-cent unit price rendered with it reads as free.
      assert Money.format(1_500) == "$0.00"
      assert Money.format(1_500, precision: 6) == "$0.001500"
      assert Money.format_compact(1_500) == "$0.0015"
    end

    test "a period is a map with a start, an end and a source" do
      assert %{start: %DateTime{}, end: %DateTime{}, source: source} =
               AuroraMeter.period(unique_tenant())

      assert is_atom(source)
    end

    test "track/3 adds, and usage/2 reads it back" do
      tenant = unique_tenant()
      AuroraMeter.track(tenant, :api_calls)
      AuroraMeter.track(tenant, :api_calls, 10)

      assert AuroraMeter.usage(tenant, :api_calls) == 11
      assert %{api_calls: 11} = AuroraMeter.usage_all(tenant)
    end
  end

  describe "team-saas.md" do
    test "the plans module carries exactly what the guide prints" do
      plans = Bramble.Plans.__aurora_plans__()

      assert plans[:free].price == 0
      assert plans[:team].price == 4_900
      assert plans[:business].price == 19_900

      # Seats are a plan value, not a counter: `feature`, not `limit`.
      assert plans[:free].features[:seats] == {:feature, 3}
      assert plans[:team].features[:seats] == {:feature, 20}

      # Switches.
      assert plans[:free].features[:pdf_export] == {:feature, false}
      assert plans[:team].features[:pdf_export] == {:feature, true}

      # Walls.
      assert plans[:free].features[:projects] == {:limit, 2, :hard}
      assert plans[:business].features[:file_uploads] == {:limit, 250_000, :hard}
    end

    test "a switch that is off refuses, and one that is on allows" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :free)
      assert AuroraMeter.check(tenant, :api_access) == {:error, :not_entitled}
      refute AuroraMeter.allowed?(tenant, :api_access)

      AuroraMeter.subscribe(tenant, :pro)
      assert AuroraMeter.check(tenant, :api_access) == :ok
      assert AuroraMeter.allowed?(tenant, :api_access)
    end

    test "feature_value/3 reads the plan's number, and falls back when undeclared" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :pro)

      assert AuroraMeter.feature_value(tenant, :seats, 1) == 5
      assert AuroraMeter.feature_value(tenant, :nothing_declared, 1) == 1
    end

    test "entitled? and allowed? differ once the allowance is gone" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :free)
      AuroraMeter.track(tenant, :ai_generations, 50)

      # The guide's point: the plan grants the feature, there is simply no room.
      assert AuroraMeter.entitled?(tenant, :ai_generations)
      refute AuroraMeter.allowed?(tenant, :ai_generations)
    end

    test "with_quota/3 admits exactly the cap under concurrency" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :free)

      results =
        1..80
        |> Task.async_stream(
          fn _ -> AuroraMeter.with_quota(tenant, :ai_generations, fn -> :made end) end,
          max_concurrency: 20,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      admitted = Enum.count(results, &match?({:ok, :made}, &1))
      refused = Enum.count(results, &(&1 == {:error, :limit_exceeded}))

      assert admitted == 50, "a hard cap of 50 must admit exactly 50, got #{admitted}"
      assert refused == 30
      assert AuroraMeter.usage(tenant, :ai_generations) == 50
    end

    test "with_quota/3 gives the reservation back when the work raises" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :free)

      assert_raise RuntimeError, fn ->
        AuroraMeter.with_quota(tenant, :ai_generations, fn -> raise "boom" end)
      end

      assert AuroraMeter.usage(tenant, :ai_generations) == 0
    end

    test "an undeclared feature is permissive" do
      assert AuroraMeter.check(unique_tenant(), :some_new_thing) == :ok
    end
  end

  describe "allowance-and-overage.md" do
    test "the plans module carries exactly what the guide prints" do
      plans = Inkwell.Plans.__aurora_plans__()

      assert plans[:free].features[:generations] == {:limit, 25, :hard}
      assert plans[:writer].features[:generations] == {:metered, 1_000, 2}
      assert plans[:studio].features[:generations] == {:metered, 5_000, 1}
    end

    test "a metered feature is never refused and reports its overage" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :scale)
      AuroraMeter.track(tenant, :ai_generations, 1_240)

      assert AuroraMeter.check(tenant, :ai_generations) == :ok
      assert AuroraMeter.remaining(tenant, :ai_generations) == :unlimited

      quota = AuroraMeter.quota(tenant, :ai_generations)

      assert quota.kind == :metered
      assert quota.used == 1_240
      assert quota.included == 1_000
      assert quota.overage == 240
      assert quota.unit_price == 2

      # percent is clamped, which is why the guides tell a renderer to read
      # `overage` instead: 1_240 of 1_000 and 10_000 of 1_000 both report 100.
      assert quota.percent == 100
    end

    test "the overage-to-money arithmetic in the guide is right" do
      # 240 units * 2 cents = 480 cents = $4.80
      assert Money.format(240 * 2 * 10_000) == "$4.80"
    end

    test "a negative track/3 corrects an overcount" do
      tenant = unique_tenant()
      AuroraMeter.track(tenant, :ai_generations, 5)
      AuroraMeter.track(tenant, :ai_generations, -1)
      assert AuroraMeter.usage(tenant, :ai_generations) == 4
    end
  end

  describe "prepaid-credits.md" do
    test "the plans module carries exactly what the guide prints" do
      plans = Parsely.Plans.__aurora_plans__()

      assert plans[:payg].features[:pages_parsed] == {:counter}
      assert plans[:payg].features[:api_requests] == {:counter}
      assert plans[:payg].features[:webhooks] == {:feature, true}
    end

    test "a counter has no denominator, and quota/2 says so with nil" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :payg)
      AuroraMeter.track(tenant, :requests, 6)

      quota = AuroraMeter.quota(tenant, :requests)

      assert quota.kind == :counter
      assert quota.used == 6
      assert quota.remaining == :unlimited

      # The whole reason the kind exists. A renderer must be able to tell
      # "no denominator" from "zero", so these are nil and never 0.
      assert is_nil(quota.limit)
      assert is_nil(quota.included)
      assert is_nil(quota.percent)
    end

    test "a grant is idempotent on its reference" do
      tenant = unique_tenant()
      reference = "stripe:pi_" <> tenant

      assert {:ok, first} = Credits.grant(tenant, Money.from_cents(2_500), reference: reference)
      assert first.amount == 25_000_000
      assert Credits.available(tenant) == 25_000_000

      # The same webhook, delivered twice.
      assert {:ok, again} = Credits.grant(tenant, Money.from_cents(2_500), reference: reference)
      assert again.id == first.id
      assert Credits.available(tenant) == 25_000_000
    end

    test "grant_with_status/3 tells new from duplicate" do
      tenant = unique_tenant()
      reference = "stripe:pi_" <> tenant

      assert {:ok, _txn, :new} =
               Credits.grant_with_status(tenant, 1_000_000, reference: reference)

      assert {:ok, _txn, :duplicate} =
               Credits.grant_with_status(tenant, 1_000_000, reference: reference)
    end

    test "hold, then settle for what it really cost" do
      tenant = unique_tenant()
      AuroraMeter.Test.fund!(tenant, 25_000_000)

      assert {:ok, _} = Credits.hold(tenant, 300_000, "doc:#{tenant}")

      # While the hold is open the money is already unavailable to other work.
      assert Credits.available(tenant) == 24_700_000

      assert {:ok, _} = Credits.settle("doc:#{tenant}", 321_000)
      assert Credits.available(tenant) == 25_000_000 - 321_000
    end

    test "release charges nothing" do
      tenant = unique_tenant()
      AuroraMeter.Test.fund!(tenant, 25_000_000)

      {:ok, _} = Credits.hold(tenant, 300_000, "doc:#{tenant}")
      assert {:ok, _} = Credits.release("doc:#{tenant}")
      assert Credits.available(tenant) == 25_000_000
    end

    test "a settlement above its hold is allowed, and goes negative honestly" do
      tenant = unique_tenant()
      AuroraMeter.Test.fund!(tenant, 500_000)

      {:ok, _} = Credits.hold(tenant, 300_000, "doc:#{tenant}")
      assert {:ok, _} = Credits.settle("doc:#{tenant}", 900_000)
      assert Credits.available(tenant) == -400_000

      # ...and the next spend is refused until a grant repairs it.
      assert {:error, :insufficient_credits} = Credits.debit(tenant, 1_000, "req:#{tenant}")
    end

    test "with_credits/4 settles the real cost" do
      tenant = unique_tenant()
      AuroraMeter.Test.fund!(tenant, 25_000_000)

      assert {:ok, "parsed"} =
               Credits.with_credits(tenant, 300_000, "doc:#{tenant}", fn ->
                 {:ok, "parsed", 214 * 1_500}
               end)

      assert Credits.available(tenant) == 25_000_000 - 321_000
    end

    test "with_credits/4 releases and charges nothing when the work fails" do
      tenant = unique_tenant()
      AuroraMeter.Test.fund!(tenant, 25_000_000)

      assert {:error, :unreadable} =
               Credits.with_credits(tenant, 300_000, "doc:#{tenant}", fn ->
                 {:error, :unreadable}
               end)

      assert Credits.available(tenant) == 25_000_000
    end

    test "refusals return, and do not roll back the caller's transaction" do
      tenant = unique_tenant()
      AuroraMeter.Test.fund!(tenant, 1_000)

      # The guide promises the caller's transaction survives a refusal. Under a
      # sandboxed DataCase this cannot fail for the right reason (the sandbox
      # absorbs an abort), so this asserts the shape only: an error tuple, not
      # a raise. The real proof is in credits_concurrency_test.exs, unsandboxed.
      assert {:error, :insufficient_credits} =
               Credits.debit(tenant, 5_000_000, "req:#{tenant}")
    end

    test "pending_holds/1 takes a DateTime and a reference prefix" do
      tenant = unique_tenant()
      AuroraMeter.Test.fund!(tenant, 25_000_000)
      {:ok, _} = Credits.hold(tenant, 300_000, "doc:#{tenant}")

      future = DateTime.add(DateTime.utc_now(), 60, :second)
      found = Credits.pending_holds(older_than: future, reference_prefix: "doc:")

      assert Enum.any?(found, &(&1.reference == "doc:#{tenant}"))

      # Nothing is older than an hour ago, so the sweeper finds none of it.
      past = DateTime.add(DateTime.utc_now(), -3_600, :second)

      refute Enum.any?(
               Credits.pending_holds(older_than: past),
               &(&1.reference == "doc:#{tenant}")
             )
    end

    test "a reversal is not a debit: it does not eat promotional credit" do
      tenant = unique_tenant()

      {:ok, _} =
        Credits.grant(tenant, 5_000_000, reference: "signup:#{tenant}", category: :promotional)

      {:ok, _} = Credits.grant(tenant, 25_000_000, reference: "stripe:pi_#{tenant}")

      before = Credits.balance(tenant).promotional
      assert before == 5_000_000

      {:ok, _} = Credits.reverse(tenant, 25_000_000, "stripe:re_#{tenant}", %{})

      assert Credits.balance(tenant).promotional == before,
             "a refund must not consume the sign-up bonus"
    end

    test "a reversal is idempotent on its reference" do
      tenant = unique_tenant()
      AuroraMeter.Test.fund!(tenant, 25_000_000)

      {:ok, _} = Credits.reverse(tenant, 1_000_000, "stripe:re_#{tenant}", %{})

      assert {:error, :duplicate_reference} =
               Credits.reverse(tenant, 1_000_000, "stripe:re_#{tenant}", %{})

      assert Credits.available(tenant) == 24_000_000
    end

    test "summary/1 reports nil rather than a misleading zero" do
      tenant = unique_tenant()
      summary = Credits.summary(tenant)

      # A brand new account has nothing honest to say about burn or runway.
      assert is_nil(summary.daily_burn)
      assert is_nil(summary.runway_days)
    end
  end

  describe "showing-usage.md" do
    test "spend_history/2 is zero-filled and oldest first" do
      tenant = unique_tenant()
      AuroraMeter.Test.fund!(tenant, 25_000_000)
      {:ok, _} = Credits.debit(tenant, 210_000, "req:#{tenant}")

      points = Credits.spend_history(tenant, days: 30)

      assert length(points) == 30
      assert Enum.map(points, & &1.date) == Enum.sort(Enum.map(points, & &1.date), Date)

      assert Enum.all?(points, &match?(%{spent: _, granted: _, net: _}, &1))
      assert Enum.any?(points, &(&1.spent == 210_000))
    end

    test "format_compact/1 keeps a sub-cent amount legible" do
      assert Money.format_compact(1_234_000_000) == "$1.2k"
      assert Money.format_compact(1_234_000) == "$1.23"
      assert Money.format_compact(70_000) == "$0.07"
      assert Money.format_compact(1_500) == "$0.0015"
      assert Money.format_compact(0) == "$0"
    end
  end

  describe "periods.md" do
    # The two modules above this test module are the guide's recipes, copied
    # verbatim. Compiling them is already a test; these run them against the
    # real contract so a recipe that stops satisfying it fails the suite.
    test "the documented daily period source satisfies the Period contract" do
      with_source(MyApp.DailyPeriod, ~U[2026-02-10 09:30:00Z], fn ->
        period = Period.current!(unique_tenant())

        assert period.start == ~U[2026-02-10 00:00:00Z]
        assert period.end == ~U[2026-02-11 00:00:00Z]
        assert period.source == :daily
      end)
    end

    test "the documented weekly period source satisfies the Period contract" do
      # 2026-02-10 is a Tuesday; its ISO week starts Monday 2026-02-09.
      with_source(MyApp.WeeklyPeriod, ~U[2026-02-10 09:30:00Z], fn ->
        period = Period.current!(unique_tenant())

        assert period.start == ~U[2026-02-09 00:00:00Z]
        assert period.end == ~U[2026-02-16 00:00:00Z]
        assert period.source == :weekly
      end)
    end

    test "the documented sources answer containing/2 for an instant one period in the past" do
      tenant = unique_tenant()

      with_source(MyApp.DailyPeriod, ~U[2026-02-10 09:30:00Z], fn ->
        assert Period.containing(tenant, ~U[2026-02-09 23:59:59Z]).start ==
                 ~U[2026-02-09 00:00:00Z]
      end)

      with_source(MyApp.WeeklyPeriod, ~U[2026-02-10 09:30:00Z], fn ->
        assert Period.containing(tenant, ~U[2026-02-08 23:59:59Z]).start ==
                 ~U[2026-02-02 00:00:00Z]
      end)
    end
  end

  describe "events-source.md" do
    test "the plans module carries exactly what the guide prints" do
      plans = Lumen.Plans.__aurora_plans__()

      assert plans[:free].features[:tokens] == {:limit, 100_000, :hard}
      assert plans[:studio].features[:tokens] == {:metered, 2_000_000, 1}
      assert plans[:studio].price == 9_900
    end

    test "the gateway gates on an estimate and charges the tokens it recorded" do
      tenant = unique_tenant()

      as_lumen(fn ->
        AuroraMeter.subscribe(tenant, :studio)

        # Warm the key, so the projection writes rather than reporting it cold.
        assert AuroraMeter.usage(tenant, :tokens) == 0

        assert {:ok, %{tokens: 1_420, text: "answer to hello"}} =
                 Lumen.Gateway.complete(tenant, "hello")

        # The estimate came back; the recorded quantity stayed. The guide's
        # arithmetic, asserted: +4_000, +1_420, -4_000.
        assert AuroraMeter.usage(tenant, :tokens) == 1_420

        period = AuroraMeter.period(tenant).start
        assert AuroraMeter.Events.total(tenant, :tokens, period) == 1_420

        # And nothing reached the table a reporter bills from.
        assert {:ok, _flushed} = AuroraMeter.Flusher.flush()
        assert AuroraMeter.Storage.load_counter(tenant, :tokens, period) == nil
      end)
    end

    test "recording the same id twice is a duplicate and charges nothing more" do
      tenant = unique_tenant()
      at = AuroraMeter.Clock.now()

      as_lumen(fn ->
        assert {:ok, _event, :inserted} =
                 AuroraMeter.record(tenant, :tokens, 1_420, id: "req_9", occurred_at: at)

        assert {:ok, _event, :duplicate} =
                 AuroraMeter.record(tenant, :tokens, 1_420, id: "req_9", occurred_at: at)

        period = AuroraMeter.period(tenant).start
        assert AuroraMeter.Events.total(tenant, :tokens, period) == 1_420

        assert {:error, {:conflict, existing}} =
                 AuroraMeter.record(tenant, :tokens, 9_999, id: "req_9", occurred_at: at)

        assert existing.quantity == 1_420
        assert AuroraMeter.Events.total(tenant, :tokens, period) == 1_420
      end)
    end

    test "track/4 and reserve/3 raise for the feature the guide moves to events" do
      tenant = unique_tenant()

      as_lumen(fn ->
        assert_raise ArgumentError, fn -> AuroraMeter.track(tenant, :tokens, 10) end
        assert_raise ArgumentError, fn -> AuroraMeter.reserve(tenant, :tokens, 10) end
      end)
    end

    test "history/3 returns zeros for the events-source feature, as the guide says" do
      tenant = unique_tenant()

      as_lumen(fn ->
        assert AuroraMeter.usage(tenant, :tokens) == 0

        assert {:ok, _event, :inserted} =
                 AuroraMeter.record(tenant, :tokens, 500,
                   id: "charted",
                   occurred_at: AuroraMeter.Clock.now()
                 )

        assert {:ok, _flushed} = AuroraMeter.Flusher.flush()

        assert AuroraMeter.history(tenant, :tokens, days: 3) |> Enum.map(& &1.value) == [0, 0, 0]
        assert AuroraMeter.usage(tenant, :tokens) == 500
      end)
    end
  end

  # The guide's two configuration lines, in one region: one `with_config` per
  # test, because a nested region queues behind itself (open-findings.md X51).
  defp as_lumen(fun) do
    TestConfig.with_config(
      [
        {:aurora_meter, :plans, Lumen.Plans},
        {:aurora_meter, :feature_sources, %{tokens: :events}}
      ],
      fun
    )
  end

  # The clock helper notices that this process already holds the configuration
  # token and does not queue behind itself (open-findings.md X51).
  defp with_source(source, instant, fun) do
    TestConfig.with_config([{:aurora_meter, :period_source, source}], fn ->
      with_clock(instant, fun)
    end)
  end
end
