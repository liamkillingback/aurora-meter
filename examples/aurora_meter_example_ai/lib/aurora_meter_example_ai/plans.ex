defmodule AuroraMeterExampleAi.Plans do
  @moduledoc """
  The two plans this sample sells, declared at compile time.

  `mix aurora_meter.install` wrote a starter version of this file with `:free`
  and `:pro` in it. This is the sample's own, and the installer never overwrites
  a plans module that already exists.

  Read it as four separate ideas, because the DSL mixes them and a first reader
  usually does not separate them:

    * `limit :images, 5, :hard` is a **quota**. It is counted in ETS, it blocks
      at the cap, and nothing about it is money.
    * `metered :tokens, included: ..., unit_price: ...` is an **allowance**.
      It counts past its included amount, it never blocks, and the overage is
      what a bill would be built from.
    * `counter :api_calls` is **measurement only**. It never blocks and it is
      never billed.
    * `recurring_credits` is the **credit ledger**, which is a different system
      from all three: it holds micro-dollars, and this sample's generation cost
      is charged against it.

  `:tokens` is declared in `config/config.exs` as `feature_sources: %{tokens:
  :events}`, so token usage is recorded durably with `AuroraMeter.record/4` and
  `AuroraMeter.track/4` raises for it. `:images` is left buffered, which is the
  cheap in-memory path. One application, both sources, and the difference is
  visible on the `/ops` page.

  ## `:studio` is paid shaped, and nothing here charges for it

  `price 4_900` is four thousand nine hundred cents, and it is a label. This
  profile of the sample takes no payment, has no card form and has no checkout.
  A plan is assigned by the seed or from the developer tools page, and the UI
  says so wherever it shows the plan name.
  """
  use AuroraMeter.Plans

  plan :free, version: "1" do
    price(0)

    # A hard quota, reported from the buffered counter. Five is small on
    # purpose: the denial is one of the things a reader should be able to reach
    # by clicking, and a cap of 500 would need a script.
    limit(:images, 5, :hard)

    # An allowance on an events-source feature. `included` is a token count and
    # `unit_price` is the overage price in cents per 1,000 tokens.
    metered(:tokens, included: 50_000, unit_price: 1)

    counter(:api_calls)
    feature(:priority_queue, false)
  end

  plan :studio, version: "1" do
    price(4_900)
    limit(:images, 200, :hard)
    metered(:tokens, included: 2_000_000, unit_price: 1)
    counter(:api_calls)
    feature(:priority_queue, true)

    # Five dollars of promotional credit per period, expiring at the period end,
    # with at most one dollar of an unused period carried forward. Granted by
    # `AuroraMeter.Credits.Recurrences.run/1`, which this sample calls from
    # `mix sample.seed` rather than from a scheduler, because a sample that
    # needs a running worker to show its first figure is a sample nobody gets
    # to the end of.
    recurring_credits(:monthly_allowance,
      amount: 5_000_000,
      category: :promotional,
      rollover: 1_000_000,
      expires: :period_end
    )
  end
end
