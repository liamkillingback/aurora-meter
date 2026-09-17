defmodule AuroraMeterExampleAi.Failures do
  @moduledoc """
  The eight failure recipes, as code that runs rather than as prose.

  `docs/failures.md` is the reader's copy. This module is what produces it: a
  recipe here triggers a real failure against a real database, reads back the
  real rows and the real ledger, runs the documented recovery, and returns a
  report. `mix sample.failure <name>` prints that report and writes it to
  `tmp/sample-failures/<name>.json`, and `test/sample_failure_test.exs`
  asserts the documented end state of every one.

  That arrangement is the point. A failure catalogue nobody runs drifts from
  the software within one release, and the drift is invisible because
  documentation does not fail a build. Here the document, the runner and the
  test are three views of the same eight facts.

  ## What every recipe reports

  Seven sections, the same seven every time:

    * **setup**: what existed before the trigger;
    * **trigger**: the exact call that caused the failure;
    * **application**: what a user or an operator sees;
    * **database**: named tables and columns, with the read that produced them;
    * **ledger**: granted, spent, held, expired, debt, balance, available and
      spendable, with the conservation identity checked;
    * **recovery**: a named function or Mix task, never a row edit;
    * **uncertain**: what is still not known, which is empty for most and
      deliberately not empty for two.

  ## Why no recovery step edits a row

  `docs/recovery.md` in Aurora Meter Pro used to tell an administrator to open
  a console and `repo.update!` a row. Build unit 04e replaced that with guarded
  operations that take an `expected:` map and have no `force:` option, and the
  reason is worth restating: a recovery is a decision about money made by a
  person who cannot see everything, and a row edit records neither the decision
  nor what they believed when they made it. Every Recovery section here names a
  function; `test/sample_failure_test.exs` fails if `docs/failures.md` ever
  contains an `UPDATE`, an `INSERT` or a `DELETE`.

  ## Isolation

  Each recipe makes its own organisation with a unique slug, so running one
  never disturbs another and running the same one twice gives two independent
  answers. Nothing here touches `acme` or `globex` from `mix sample.seed`.
  """

  import Ecto.Query

  alias AuroraMeter.Credits
  alias AuroraMeter.Exporter.Journal
  alias AuroraMeterExampleAi.Accounts
  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAi.Generations.Generation
  alias AuroraMeterExampleAi.Ops
  alias AuroraMeterExampleAi.Orgs
  alias AuroraMeterExampleAi.Repo
  alias AuroraMeterExampleAi.SampleOutbox.Drainer
  alias AuroraMeterExampleAi.SampleOutbox.Item
  alias AuroraMeterExampleAi.Tenancy
  alias AuroraMeterExampleAi.Tokens

  @core_recipes ~w(insufficient_balance callback_raise untrappable_death worker_retry
                   duplicate_event exporter_timeout late_correction)
  @pro_recipes ~w(customer_cancellation)

  @doc """
  Every recipe, with the profile it needs and one line about what it shows.

  The names are the document's headings. `test/sample_failure_test.exs` parses
  `docs/failures.md` and asserts the two lists are the same set in both
  directions, so a recipe cannot be documented and not implemented, or
  implemented and not documented.
  """
  @spec recipes() :: [%{name: String.t(), profile: :core | :pro, shows: String.t()}]
  def recipes do
    [
      %{
        name: "insufficient_balance",
        profile: :core,
        shows: "a refusal before any work, and the two different reasons a wallet can refuse"
      },
      %{
        name: "callback_raise",
        profile: :core,
        shows: "a raise inside the work, and the hold and reservation coming back"
      },
      %{
        name: "untrappable_death",
        profile: :core,
        shows: "a process killed between the durable event and this application's own row"
      },
      %{
        name: "worker_retry",
        profile: :core,
        shows: "two delivery attempts and one effect"
      },
      %{
        name: "duplicate_event",
        profile: :core,
        shows: "one identity recorded twice: one event, one delta, one intent"
      },
      %{
        name: "exporter_timeout",
        profile: :core,
        shows: "an outcome nobody knows, which is never retried automatically"
      },
      %{
        name: "late_correction",
        profile: :core,
        shows: "a correction after the period, bounded and immutable"
      },
      %{
        name: "customer_cancellation",
        profile: :pro,
        shows: "a cancelled subscription and a refunded top-up, reversed once"
      }
    ]
  end

  @doc "The names of every recipe."
  @spec names() :: [String.t()]
  def names, do: Enum.map(recipes(), & &1.name)

  @doc """
  Runs one recipe and returns its report.

  Options:

    * `:apply_recovery` (default `true`) run the documented recovery step too,
      and report what it produced. `false` stops after the observation, which
      is what a reader wants when they intend to look at the rows themselves.
    * `:slug_suffix` a string that makes this run's organisation slug unique.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(name, opts \\ []) do
    cond do
      name in @core_recipes -> {:ok, execute(name, opts)}
      name in @pro_recipes -> run_pro(name, opts)
      true -> {:error, {:unknown_recipe, name, names()}}
    end
  end

  defp run_pro(name, opts) do
    # A Pro recipe aborts by name rather than degrading into a demonstration
    # of something else. There is no simulated refund here and there is not
    # going to be one.
    AuroraMeterExampleAi.Pro.require!("The #{name} recipe")
    {:ok, execute(name, opts)}
  end

  ## ---------------------------------------------------------------------
  ## The recipes
  ## ---------------------------------------------------------------------

  defp execute("insufficient_balance", opts) do
    ctx = setup(opts, credit: 0, name: "insufficient_balance")
    request_id = Ecto.UUID.generate()

    before = ledger(ctx)

    # Leg 1: a wallet with nothing in it.
    empty = Generations.create(ctx.scope, text_params(), request_id)

    # Leg 2: a wallet that OWES money. R3 made these two refusals different,
    # and a recipe that showed only the first would leave a reader believing
    # `:insufficient_credits` is the only way a hold can be refused.
    indebted = indebted_org(opts)
    in_debt = Generations.create(indebted.scope, text_params(), Ecto.UUID.generate())

    report(ctx, %{
      recipe: "insufficient_balance",
      setup: [
        "org #{ctx.org.slug} on the :studio plan with a wallet holding nothing at all",
        "org #{indebted.org.slug} on the :studio plan, granted 2 USD paid and 4 USD " <>
          "promotional, then charged a 5 USD reversal. The paid lot covers 2 USD of it and " <>
          "the promotion is never taken to repay a debt, so the wallet ends up owing 3 USD " <>
          "while still holding 4 USD of promotional credit"
      ],
      trigger:
        ~s|Generations.create(scope, %{"kind" => "text", "prompt" => "...", "model" => "nimbus-1-mini"}, request_id)|,
      application: %{
        empty_wallet_returns: inspect(empty),
        indebted_wallet_returns: inspect(in_debt),
        what_the_page_shows:
          "the refusal text for each reason; the debt banner is shown for the second"
      },
      database: %{
        generations_rows: generation_rows(ctx),
        sample_outbox_items: outbox_rows(ctx),
        note:
          "no generations row and no outbox item for either leg: the refusal happens at the " <>
            "credit hold, before the work runs and before anything is recorded"
      },
      ledger: %{
        before: before,
        after: ledger(ctx),
        indebted: ledger(indebted),
        unchanged: before == ledger(ctx)
      },
      recovery: %{
        needed: false,
        command:
          "none. Grant credit: AuroraMeter.Credits.grant(org, amount, reference: \"...\", " <>
            "category: :paid). For the indebted wallet a grant of any category clears the " <>
            "debt first and only the remainder becomes spendable.",
        ran: false
      },
      uncertain: []
    })
  end

  defp execute("callback_raise", opts) do
    ctx = setup(opts, credit: 5_000_000, name: "callback_raise")
    request_id = Ecto.UUID.generate()
    before = ledger(ctx)
    usage_before = AuroraMeter.usage(ctx.org, :tokens)

    # `fail:` makes the simulated workload raise `Tokens.ProviderError` from
    # inside the `with_credits/4` callback, which is the channel the library
    # documents for "the work did not happen".
    outcome =
      Generations.create(
        ctx.scope,
        %{"kind" => "image", "prompt" => "fail: the provider refused", "model" => "nimbus-1"},
        request_id
      )

    report(ctx, %{
      recipe: "callback_raise",
      setup: ["org #{ctx.org.slug} with 5 USD of paid credit, on the :studio plan"],
      trigger: ~s|Generations.create(scope, %{"kind" => "image", "prompt" => "fail: ..."}, id)|,
      application: %{
        returns: inspect(outcome),
        what_the_page_shows: "The work failed. Nothing was charged and the quota was given back."
      },
      database: %{
        generations_rows: generation_rows(ctx),
        sample_outbox_items: outbox_rows(ctx),
        note:
          "one generations row with status \"rejected\" so the attempt is visible in the " <>
            "history, and NO outbox item, because nothing was ever recorded"
      },
      ledger: %{
        before: before,
        after: ledger(ctx),
        held_returned: ledger(ctx).held == before.held,
        balance_unchanged: ledger(ctx).balance == before.balance,
        usage_before: usage_before,
        usage_after: AuroraMeter.usage(ctx.org, :tokens),
        quota_images: inspect(AuroraMeter.quota(ctx.org, :images))
      },
      recovery: %{
        needed: false,
        command: "none. The hold and the quota reservation were both released on the way out.",
        ran: false
      },
      uncertain: []
    })
  end

  defp execute("untrappable_death", opts) do
    ctx = setup(opts, credit: 5_000_000, name: "untrappable_death")
    request_id = Ecto.UUID.generate()
    before = ledger(ctx)

    # A real kill, at a real seam. `arm/2` puts a function in the calling
    # process's dictionary and `Generations.create/3` calls it after
    # `AuroraMeter.record/4` has committed the event, its projection delta and
    # its export intent, and before this application writes its own row.
    #
    # `Process.exit(self(), :kill)` cannot be trapped, cannot run an `after`
    # block and cannot run an `on_exit`. Whatever survives, survives because it
    # was committed.
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        Generations.arm(:after_record, fn ->
          send(parent, {:about_to_die, self()})
          Process.exit(self(), :kill)
        end)

        Generations.create(ctx.scope, text_params(), request_id)
      end)

    ref = Process.monitor(pid)

    died =
      receive do
        {:DOWN, ^ref, :process, ^pid, reason} -> inspect(reason)
      after
        5_000 -> "the process did not die within 5s"
      end

    reached_the_seam =
      receive do
        {:about_to_die, ^pid} -> true
      after
        0 -> false
      end

    reference = Generations.reference(request_id)
    item = Repo.get_by(Item, tenant_key: ctx.tenant_key, event_id: reference)
    row = Repo.get(Generation, request_id)
    orphans_before = length(Ops.orphans(ctx.scope))
    after_kill = ledger(ctx)

    # The hold that nobody closed. This is the half of the recipe that the
    # first version of it got wrong: the note said "the credit was settled",
    # and the ledger says otherwise. The kill lands INSIDE the
    # `Credits.with_credits/4` callback, after `record/4` returned and before
    # the callback did, so the settle never happened and the reservation is
    # still standing.
    stranded =
      Credits.pending_holds(
        tenant: ctx.org,
        older_than: DateTime.add(DateTime.utc_now(), 1, :second),
        reference_prefix: "gen:"
      )

    recovery = maybe_recover(opts, ctx)
    holds = maybe_reconcile_holds(opts, ctx)

    report(ctx, %{
      recipe: "untrappable_death",
      setup: ["org #{ctx.org.slug} with 5 USD of paid credit"],
      trigger:
        "Generations.arm(:after_record, fn -> Process.exit(self(), :kill) end) inside a Task, " <>
          "then Generations.create(scope, attrs, request_id) in that Task",
      application: %{
        process_exit_reason: died,
        reached_the_seam: reached_the_seam,
        what_the_user_sees:
          "nothing: the request died. A retry of the same request id is answered by the " <>
            "replay path, which finds the export intent and rebuilds the row"
      },
      database: %{
        generations_row_present: not is_nil(row),
        sample_outbox_item_present: not is_nil(item),
        outbox_item:
          item &&
            %{
              event_id: item.event_id,
              feature: item.feature,
              quantity: item.quantity,
              state: item.state
            },
        orphans_reported_by_ops: orphans_before,
        # `held_delta`, NOT `amount`. `Credits.pending_holds/1` returns raw
        # ledger transactions, and on a hold row `amount` is 0 because a hold
        # moves the reserved figure and not the balance. The reservation is in
        # `held_delta`. `Credits.reconcile_holds/1` maps the same column into
        # the reconciler's `hold.amount`, so the two halves of one documented
        # job use the word "amount" for two different things and only one of
        # them is the money. Reported to the library as open finding X396; the
        # recipe prints both so the difference is visible rather than
        # surprising.
        pending_holds:
          Enum.map(
            stranded,
            &%{
              reference: &1.reference,
              held_delta: &1.held_delta,
              amount_column: &1.amount,
              status: &1.status
            }
          ),
        query:
          "SELECT event_id, feature, quantity, state FROM sample_outbox_items " <>
            "WHERE tenant_key = '#{ctx.tenant_key}'; " <>
            "SELECT id, status FROM generations WHERE org_id = #{ctx.org.id}; " <>
            "and AuroraMeter.Credits.pending_holds(tenant: org, older_than: t, " <>
            "reference_prefix: \"gen:\") for the reservation"
      },
      ledger: %{
        before: before,
        after_the_kill: after_kill,
        after_recovery: ledger(ctx),
        held_after_the_kill: after_kill.held,
        note:
          "**the hold is still open.** The kill lands inside the " <>
            "`Credits.with_credits/4` callback, after `record/4` committed the event and " <>
            "before the callback returned, so the settle never happened. The money is not " <>
            "wrong, it is pending: `held` is the estimate and `available` is that much lower " <>
            "until somebody decides. Nothing releases it on its own, ever, and the age of the " <>
            "hold is not evidence of anything"
      },
      recovery: %{
        needed: true,
        command:
          "two steps, and they answer two different questions.\n\n" <>
            "  1. `mix sample.repair --apply` rebuilds this application's missing row from " <>
            "the export intent.\n" <>
            "  2. `AuroraMeter.Credits.reconcile_holds(older_than: t)` asks " <>
            "`AuroraMeterExampleAi.HoldPolicy` about the open hold and applies the answer. " <>
            "The policy decides from the export intent (the work finished, settle for what it " <>
            "really cost) and never from the hold's age.",
        ran: recovery.ran,
        result: recovery.result,
        generations_row_after: recovery.ran and not is_nil(Repo.get(Generation, request_id)),
        holds: holds,
        what_cannot_be_rebuilt:
          "the prompt. It is customer content, it was never durable, and the rebuilt row says " <>
            "so rather than inventing one"
      },
      uncertain: []
    })
  end

  defp execute("worker_retry", opts) do
    ctx = setup(opts, credit: 5_000_000, name: "worker_retry")
    request_id = Ecto.UUID.generate()
    reference = Generations.reference(request_id)

    {:ok, _generation, :created} = Generations.create(ctx.scope, text_params(), request_id)

    # The reference exporter is scripted per subject reference: fail the first
    # delivery with a retry, accept the second. Nothing is mocked; this is the
    # exporter the sample ships, answering what it was told to.
    Journal.script(reference, [{:retry, 1}, :accepted])

    first = Drainer.drain_now()
    after_first = Repo.get_by(Item, tenant_key: ctx.tenant_key, event_id: reference)

    # The retry schedules `next_attempt_at` a second out, and the drainer
    # honours it, so the recipe waits rather than pretending it did not.
    Process.sleep(1_100)
    second = Drainer.drain_now()
    after_second = Repo.get_by(Item, tenant_key: ctx.tenant_key, event_id: reference)

    deliveries = Journal.deliveries_for(reference)

    report(ctx, %{
      recipe: "worker_retry",
      setup: ["one settled generation, one pending outbox item"],
      trigger:
        "AuroraMeter.Exporter.Journal.script(reference, [{:retry, 1}, :accepted]) " <>
          "then two ticks of AuroraMeterExampleAi.SampleOutbox.Drainer.drain_now/1",
      application: %{
        first_tick: inspect(first),
        second_tick: inspect(second),
        what_ops_shows: "the item goes pending -> claimed -> pending -> claimed -> delivered"
      },
      database: %{
        after_first_tick: %{
          state: after_first.state,
          attempts: after_first.attempts,
          last_outcome: after_first.last_outcome
        },
        after_second_tick: %{
          state: after_second.state,
          attempts: after_second.attempts,
          last_outcome: after_second.last_outcome,
          provider_ref: after_second.provider_ref
        },
        query:
          "SELECT state, attempts, last_outcome, provider_ref FROM sample_outbox_items " <>
            "WHERE event_id = '#{reference}';"
      },
      effects: %{
        delivery_attempts: length(deliveries),
        accepted_deliveries: Enum.count(deliveries, &(&1.outcome == :accepted)),
        # The documented end state names the EFFECT count, never the run count.
        # A worker that ran twice and had one effect is correct; a worker that
        # ran once is a claim about scheduling nobody can make.
        statement: "two delivery attempts, one accepted delivery, one item delivered"
      },
      ledger: %{after: ledger(ctx), note: "delivery does not touch the ledger"},
      recovery: %{
        needed: false,
        command:
          "none. At-least-once scheduling with an idempotent effect is the correct shape, and " <>
            "this is what it looks like when it works.",
        ran: false
      },
      uncertain: [],
      note:
        "the `attempts` column reads 1 after a retry and a success, not 2. It counts RETRIES, " <>
          "not attempts: only `{:retry, _}` increments it, because an accepted, rejected or " <>
          "uncertain item is not going to be sent again and counting the attempt that ended " <>
          "it would make the figure mean two different things. The delivery count above is " <>
          "the figure that answers \"how many times did this leave the building\""
    })
  end

  defp execute("duplicate_event", opts) do
    ctx = setup(opts, credit: 5_000_000, name: "duplicate_event")
    id = "dup:" <> Ecto.UUID.generate()
    occurred_at = DateTime.utc_now()

    usage_before = AuroraMeter.usage(ctx.org, :tokens)

    opts_for_record = [
      id: id,
      occurred_at: occurred_at,
      dimensions: %{"model" => "nimbus-1-mini", "kind" => "text"},
      metadata: %{"why" => "the duplicate_event recipe"}
    ]

    first = AuroraMeter.record(ctx.org, :tokens, 40, opts_for_record)
    second = AuroraMeter.record(ctx.org, :tokens, 40, opts_for_record)

    # And the half a reader gets wrong: the SAME id with a different payload is
    # a conflict, not a duplicate, and the difference can be one microsecond of
    # `occurred_at`.
    third =
      AuroraMeter.record(
        ctx.org,
        :tokens,
        40,
        Keyword.put(opts_for_record, :occurred_at, DateTime.add(occurred_at, 1, :microsecond))
      )

    items =
      Repo.all(from(i in Item, where: i.tenant_key == ^ctx.tenant_key and i.event_id == ^id))

    report(ctx, %{
      recipe: "duplicate_event",
      setup: ["org #{ctx.org.slug}, nothing recorded yet this period"],
      trigger:
        "AuroraMeter.record(org, :tokens, 40, id: same, occurred_at: same) twice, then once " <>
          "more with occurred_at one microsecond later",
      application: %{
        first_call: inspect(first),
        second_call: inspect(second),
        third_call_with_a_different_payload: inspect(third)
      },
      database: %{
        sample_outbox_items_for_that_id: length(items),
        item:
          case items do
            [item] -> %{state: item.state, quantity: item.quantity, attempts: item.attempts}
            other -> other
          end,
        query:
          "SELECT count(*) FROM sample_outbox_items WHERE tenant_key = '#{ctx.tenant_key}' " <>
            "AND event_id = '#{id}';"
      },
      projection: %{
        usage_before: usage_before,
        usage_after: AuroraMeter.usage(ctx.org, :tokens),
        delta: AuroraMeter.usage(ctx.org, :tokens) - usage_before,
        statement: "one event, one projection delta of 40, one outbox item"
      },
      ledger: %{after: ledger(ctx), note: "record/4 does not touch the ledger"},
      recovery: %{
        needed: false,
        command: "none. A repeated identity with the same payload is reported, not persisted.",
        ran: false
      },
      uncertain: [],
      note:
        "the third call is the one worth reading twice. `record/4`'s identity covers the whole " <>
          "payload including `occurred_at` to the microsecond, so \"retry with the same id\" " <>
          "means retry with the same id AND the same payload. A caller that stamps a fresh " <>
          "DateTime.utc_now() on a retry gets a conflict, which is correct and is not what the " <>
          "sentence in the documentation leads you to build (open-findings X381)"
    })
  end

  defp execute("exporter_timeout", opts) do
    ctx = setup(opts, credit: 5_000_000, name: "exporter_timeout")
    request_id = Ecto.UUID.generate()
    reference = Generations.reference(request_id)

    {:ok, _generation, :created} = Generations.create(ctx.scope, text_params(), request_id)

    # `:uncertain` is the exporter saying "the provider may or may not have
    # taken this, and I cannot tell". It is the lost-acknowledgement case and
    # it is the only outcome that must never be retried by a machine.
    Journal.script(reference, [:uncertain, :accepted])

    first = Drainer.drain_now()
    item = Repo.get_by(Item, tenant_key: ctx.tenant_key, event_id: reference)

    # The proof that it is not retried: tick again, several times, and watch
    # nothing happen. A scripted `:accepted` is waiting behind the
    # `:uncertain`, so if anything DID retry it, the item would go to
    # `delivered` and this assertion would fail loudly rather than quietly.
    Enum.each(1..3, fn _ -> Drainer.drain_now() end)
    Process.sleep(50)
    still = Repo.get_by(Item, tenant_key: ctx.tenant_key, event_id: reference)

    horizon_seconds = 23 * 60 * 60
    age = DateTime.diff(DateTime.utc_now(), still.updated_at)

    recovery = uncertain_recovery(ctx, still)

    report(ctx, %{
      recipe: "exporter_timeout",
      setup: ["one settled generation, one pending outbox item"],
      trigger:
        "AuroraMeter.Exporter.Journal.script(reference, [:uncertain, :accepted]) then " <>
          "four ticks of the drainer",
      application: %{
        first_tick: inspect(first),
        what_ops_shows:
          "the item sits in the uncertain bucket with its age beside the 23 hour horizon, and " <>
            "the page says a human has to decide"
      },
      database: %{
        after_first_tick: %{
          state: item.state,
          attempts: item.attempts,
          last_outcome: item.last_outcome,
          next_attempt_at: item.next_attempt_at
        },
        after_three_more_ticks: %{state: still.state, attempts: still.attempts},
        never_retried: still.state == "uncertain" and is_nil(still.next_attempt_at),
        age_seconds: age,
        horizon_seconds: horizon_seconds,
        within_horizon: age < horizon_seconds,
        query:
          "SELECT state, attempts, last_outcome, next_attempt_at, updated_at " <>
            "FROM sample_outbox_items WHERE event_id = '#{reference}';"
      },
      ledger: %{
        after: ledger(ctx),
        note:
          "the customer was charged when the work ran. Whether the provider was told is the " <>
            "open question, and it is a question about an invoice rather than about this ledger"
      },
      recovery: recovery,
      uncertain: [
        # The first entry is the programme's own words, quoted, so that this
        # list and `financial-correctness-review.md` section 8 can be compared
        # rather than believed. The section's first bullet reads: "Provider
        # meter event acceptance vs asynchronous rejection: `accepted` until
        # reconciled."
        "financial-correctness-review.md section 8, first bullet: \"Provider meter event " <>
          "acceptance vs asynchronous rejection: `accepted` until reconciled.\" This " <>
          "application's teaching outbox has no `accepted` and no `confirmed`; it has " <>
          "`uncertain`, which is the same fact with fewer words. Aurora Meter Pro's outbox " <>
          "has both, and the reconciler is what moves one to the other.",
        "Whether the provider accepted this item. `:uncertain` means the request may have " <>
          "arrived and the answer may have been lost, and no amount of retrying can " <>
          "distinguish those two.",
        "An empty search at the provider is NOT proof that nothing arrived, and a zero on an " <>
          "invoice is not either. If you cannot show that the request did not land, leave it " <>
          "uncertain: under-billing is recoverable and double-billing is a refund and an " <>
          "apology.",
        "After the 23 hour horizon the provider's own idempotency key may have expired, so a " <>
          "resend stops being the same request and becomes a second one. That is the point " <>
          "after which the decision can no longer be undone by waiting."
      ]
    })
  end

  defp execute("late_correction", opts) do
    ctx = setup(opts, credit: 5_000_000, name: "late_correction")
    request_id = Ecto.UUID.generate()
    reference = Generations.reference(request_id)

    {:ok, generation, :created} = Generations.create(ctx.scope, text_params(), request_id)

    # Deliver the original first, so the correction really is late: the
    # provider has already been told the larger number.
    Drainer.drain_now()
    delivered = Repo.get_by(Item, tenant_key: ctx.tenant_key, event_id: reference)

    original_quantity = generation.prompt_tokens + generation.completion_tokens
    reduce_by = max(div(original_quantity, 4), 1)
    correction_id = "credit:" <> Ecto.UUID.generate()

    corrected =
      AuroraMeter.correct(ctx.org, reference, reduce_by,
        id: correction_id,
        metadata: %{"ticket" => "SUP-42", "why" => "the late_correction recipe"}
      )

    # The bound: the cumulative magnitude of corrections can never exceed the
    # original. Asking for more is refused, and the refusal is part of the
    # recipe rather than a footnote.
    over =
      AuroraMeter.correct(ctx.org, reference, original_quantity,
        id: "credit:" <> Ecto.UUID.generate()
      )

    # And a repeat of the same correction id is a duplicate, not a second
    # credit, even now that the original is partly corrected.
    repeat =
      AuroraMeter.correct(ctx.org, reference, reduce_by,
        id: correction_id,
        metadata: %{"ticket" => "SUP-42", "why" => "the late_correction recipe"}
      )

    correction_items =
      Repo.all(
        from(i in Item,
          where: i.tenant_key == ^ctx.tenant_key and i.event_id == ^correction_id
        )
      )

    tick = Drainer.drain_now()

    report(ctx, %{
      recipe: "late_correction",
      setup: [
        "one settled generation of #{original_quantity} tokens",
        "its outbox item already delivered, so the provider has been told the larger number"
      ],
      trigger:
        "AuroraMeter.correct(org, \"#{reference}\", #{reduce_by}, id: \"#{correction_id}\", " <>
          "metadata: %{\"ticket\" => \"SUP-42\"})",
      application: %{
        correction: inspect(corrected),
        over_correction_refused: inspect(over),
        repeated_correction_id: inspect(repeat),
        what_ops_shows: "two outbox items for one request: the original, and the correction"
      },
      database: %{
        original_item: %{
          event_id: delivered.event_id,
          state: delivered.state,
          quantity: delivered.quantity
        },
        correction_items:
          Enum.map(correction_items, fn i ->
            %{
              event_id: i.event_id,
              state: i.state,
              quantity: i.quantity,
              last_outcome: i.last_outcome
            }
          end),
        drain_after_correction: inspect(tick),
        nothing_was_updated:
          "the original row is untouched. A correction is its own row pointing at the event " <>
            "it reduces, and both stay in the history for ever",
        query:
          "SELECT event_id, state, quantity, last_outcome FROM sample_outbox_items " <>
            "WHERE tenant_key = '#{ctx.tenant_key}' ORDER BY inserted_at;"
      },
      quantities: %{
        original: original_quantity,
        reduced_by: reduce_by,
        net_expected: original_quantity - reduce_by,
        usage_now: AuroraMeter.usage(ctx.org, :tokens),
        bound_holds: match?({:error, {:invalid, _}}, over)
      },
      ledger: %{
        after: ledger(ctx),
        note:
          "a correction reduces the QUANTITY reported for billing. It does not refund credit: " <>
            "the customer paid this application for work this application did, and what was " <>
            "over-reported to the provider is a different conversation"
      },
      recovery: %{
        needed: true,
        command:
          "In the core profile: none is possible, and that is the honest answer. The provider " <>
            "has the larger number and this application has no way to talk to it. In the Pro " <>
            "profile the correction is staged for export and, when the adjustment window has " <>
            "closed, quarantined as a reconciliation item that names the difference: " <>
            "AuroraMeter.Pro.Recovery.list_uncertain/1 and the /ops page show it, and the " <>
            "operator settles it with Stripe.",
        ran: false
      },
      uncertain: [
        "Whether the provider will accept the adjustment at all. Stripe's meter event " <>
          "adjustment window is finite and an invoice that has been finalised is never " <>
          "edited by this software.",
        "What the customer should be charged, once the invoice and the corrected quantity " <>
          "disagree. The software reports the difference; a person decides what to do about " <>
          "it, and that is a commercial decision rather than a defect."
      ]
    })
  end

  defp execute("customer_cancellation", opts) do
    ctx = setup(opts, credit: 0, name: "customer_cancellation")

    # This recipe is Pro's, and every figure in it comes from a real Stripe
    # test-mode object. It is driven by `scripts/pro-proof.sh`, which creates
    # the subscription, the top-up and the refund, because a cancellation
    # needs a provider and there is no honest way to fake one here.
    report(ctx, %{
      recipe: "customer_cancellation",
      setup: [
        "org #{ctx.org.slug} subscribed to :studio in Stripe test mode",
        "one top-up paid with 4242 4242 4242 4242, granted by the webhook",
        "auto-recharge armed, so the race between a manual top-up and an automatic one is in " <>
          "scope"
      ],
      trigger:
        "scripts/pro-proof.sh --cancel, which runs `stripe delete /v1/subscriptions/<id> " <>
          "--confirm` (never `stripe subscriptions cancel`, which hangs on a prompt when it " <>
          "is not attached to a terminal) and then refunds the last charge",
      application: %{
        note:
          "this recipe reports from the proof run's JSON rather than triggering Stripe from " <>
            "a Mix task. Creating a subscription from `mix sample.failure` would put a real " <>
            "provider call behind a command a reader runs by habit."
      },
      database: %{
        note: "see docs/evidence/v1/phase-09/pro-proof/summary.json for the observed rows"
      },
      ledger: %{after: ledger(ctx)},
      recovery: %{
        needed: false,
        command:
          "none. The reversal rows are the record: one reversal per refund, and a redelivered " <>
            "refund event reverses nothing further.",
        ran: false
      },
      uncertain: []
    })
  end

  ## ---------------------------------------------------------------------
  ## Shared machinery
  ## ---------------------------------------------------------------------

  defp text_params do
    %{"kind" => "text", "prompt" => "a poem about a ledger", "model" => "nimbus-1-mini"}
  end

  defp setup(opts, attrs) do
    suffix =
      Keyword.get(opts, :slug_suffix, Integer.to_string(System.unique_integer([:positive])))

    # An organisation slug is lower case letters, digits and hyphens, and the
    # recipe names carry underscores. The slug is derived rather than assumed,
    # because `Orgs.create_org/1` refuses the underscore and the refusal is
    # right.
    slug = "failure-#{String.replace(to_string(attrs[:name]), "_", "-")}-#{suffix}"

    {:ok, org} = Orgs.create_org(%{slug: slug, name: "Failure recipe: #{attrs[:name]}"})

    # Before the first grant, for the reason `mix sample.seed` explains at
    # length. On a release with X383's change a new wallet is born on lots and
    # this is a no-op; on one without it, it is the difference between a recipe
    # that can show a lot and one that cannot.
    enable_lots(org)

    AuroraMeter.subscribe(org, :studio)

    user = user_for(org, slug)
    scope = %Scope{user: user, org: org}

    case attrs[:credit] do
      0 ->
        :ok

      amount ->
        {:ok, _} =
          Credits.grant(org, amount,
            reference: "recipe:#{slug}:paid",
            category: :paid,
            metadata: %{"why" => "a failure recipe, no payment was taken"}
          )
    end

    %{org: org, scope: scope, user: user, tenant_key: Tenancy.to_key(org)}
  end

  # A wallet that owes money, built the way a wallet really comes to owe money:
  # a refund larger than what is left. R1 and R2 made this reachable and R3
  # made the figures honest about it; before them `:debt_outstanding` was a
  # state a new installation could not enter at all.
  defp indebted_org(opts) do
    ctx = setup(opts, credit: 0, name: "insufficient_balance-debt")

    {:ok, _} =
      Credits.grant(ctx.org, 2_000_000,
        reference: "recipe:#{ctx.org.slug}:paid",
        category: :paid
      )

    {:ok, _} =
      Credits.grant(ctx.org, 4_000_000,
        reference: "recipe:#{ctx.org.slug}:promo",
        category: :promotional
      )

    # Reverse more than the paid grant holds. Debt is never repaid out of a
    # promotion (R2), so the wallet ends up owing money AND holding credit.
    _ =
      Credits.reverse(ctx.org, 5_000_000, "recipe:#{ctx.org.slug}:refund", %{
        "why" => "a refund larger than what is left, which is how a wallet comes to owe"
      })

    ctx
  end

  defp enable_lots(org) do
    AuroraMeter.Credits.Ledger.enable_lots!(Tenancy.to_key(org))
  rescue
    ArgumentError -> :already
  end

  defp user_for(org, slug) do
    email = "owner@#{slug}.example.com"

    user =
      case Repo.get_by(Accounts.User, email: email) do
        nil ->
          {:ok, user} = Accounts.register_user(%{email: email})
          user

        user ->
          user
      end

    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
    |> Repo.update!()
    |> Accounts.User.org_changeset(%{org_id: org.id, role: "owner"})
    |> Repo.update!()
  end

  defp ledger(ctx) do
    summary = Credits.summary(ctx.org)
    conservation = Ops.conservation(ctx.scope)

    history =
      Credits.history(ctx.org, kinds: [:grant, :settle, :debit, :reverse, :expire], limit: 500)

    %{
      balance: summary.balance,
      held: summary.held,
      available: summary.available,
      spendable: summary.spendable,
      promotional: summary.promotional,
      promotional_spendable: summary.promotional_spendable,
      debt: summary.debt,
      expired: summary.expired,
      granted: sum_where(history, &(&1.amount > 0)),
      spent: abs(sum_where(history, &(&1.amount < 0))),
      entries: length(history),
      conservation: %{
        balance_holds: conservation.balance_holds,
        held_holds: conservation.held_holds,
        available_holds: conservation.available_holds,
        identity:
          "sum(entry.amount) == balance, sum(entry.held_delta) == held, " <>
            "balance - held == available",
        holds: conservation.holds
      },
      lots: Enum.map(Credits.Lots.list(ctx.org, states: :all, limit: 20), &lot_row/1)
    }
  end

  defp lot_row(lot) do
    %{
      category: Map.get(lot, :category),
      amount: Map.get(lot, :amount),
      available: Map.get(lot, :available),
      reserved: Map.get(lot, :reserved),
      consumed: Map.get(lot, :consumed),
      reversed: Map.get(lot, :reversed),
      expired: Map.get(lot, :expired),
      state: Map.get(lot, :state),
      expires_at: Map.get(lot, :expires_at)
    }
  end

  defp sum_where(history, fun),
    do: history |> Enum.filter(fun) |> Enum.reduce(0, &(&1.amount + &2))

  defp generation_rows(ctx) do
    Generation
    |> where([g], g.org_id == ^ctx.org.id)
    |> order_by([g], asc: g.inserted_at)
    |> Repo.all()
    |> Enum.map(fn g ->
      %{
        id: g.id,
        status: g.status,
        event_id: g.event_id,
        cost_micros: g.cost_micros,
        estimate_micros: g.estimate_micros
      }
    end)
  end

  defp outbox_rows(ctx) do
    Item
    |> where([i], i.tenant_key == ^ctx.tenant_key)
    |> order_by([i], asc: i.inserted_at)
    |> Repo.all()
    |> Enum.map(fn i ->
      %{
        event_id: i.event_id,
        feature: i.feature,
        quantity: i.quantity,
        state: i.state,
        attempts: i.attempts,
        last_outcome: i.last_outcome
      }
    end)
  end

  # The second recovery step, and the one that touches money. It goes through
  # the configured reconciler rather than through a row edit, and the decision
  # is made by this application from a fact it owns.
  defp maybe_reconcile_holds(opts, ctx) do
    if Keyword.get(opts, :apply_recovery, true) do
      {:ok, report} =
        Credits.reconcile_holds(
          tenant: ctx.org,
          older_than: DateTime.add(DateTime.utc_now(), 1, :second),
          reference_prefix: "gen:"
        )

      %{
        ran: true,
        examined: Map.get(report, :examined),
        settled: Map.get(report, :settled),
        released: Map.get(report, :released),
        kept: Map.get(report, :kept),
        report: inspect(report)
      }
    else
      %{ran: false}
    end
  end

  defp maybe_recover(opts, ctx) do
    if Keyword.get(opts, :apply_recovery, true) do
      orphans = Ops.orphans(ctx.scope)
      rebuilt = Enum.map(orphans, &rebuild_orphan(ctx, &1))
      %{ran: true, result: %{orphans: length(orphans), rebuilt: rebuilt}}
    else
      %{ran: false, result: nil}
    end
  end

  # The same thing `mix sample.repair --apply` does, called directly so the
  # recipe can report what it produced. The Mix task is the documented command;
  # this is the code behind it, and the test asserts they agree.
  defp rebuild_orphan(ctx, item) do
    total = item.quantity
    dimensions = Map.get(item.payload, "dimensions", %{})
    prompt = "(not recovered: the prompt was never recorded durably)"
    prompt_tokens = Tokens.prompt_tokens(prompt)
    completion = max(total - prompt_tokens, 0)

    attrs = %{
      id: strip_prefix(item.event_id),
      org_id: ctx.org.id,
      user_id: ctx.user.id,
      kind: Map.get(dimensions, "kind", "text"),
      prompt: prompt,
      model: Map.get(dimensions, "model", "nimbus-1-mini"),
      status: "settled",
      prompt_tokens: prompt_tokens,
      completion_tokens: completion,
      cost_micros: Tokens.cost_micros(prompt_tokens, completion),
      event_id: item.event_id,
      hold_reference: item.event_id,
      inserted_at: item.inserted_at,
      settled_at: item.inserted_at
    }

    case %Generation{} |> Generation.changeset(attrs) |> Repo.insert() do
      {:ok, generation} ->
        %{event_id: item.event_id, rebuilt: true, id: generation.id}

      {:error, changeset} ->
        %{event_id: item.event_id, rebuilt: false, errors: inspect(changeset.errors)}
    end
  end

  defp strip_prefix("gen:" <> uuid), do: uuid
  defp strip_prefix(other), do: other

  # The Recovery section for an uncertain item, in both profiles, and the
  # difference between them is the whole argument for the commercial tier.
  # Two definitions behind a compile-time `if`, not one with a runtime branch:
  # `available?/0` is a compile-time constant and a runtime `if` on it is a
  # branch the type checker can see will never be taken.
  if AuroraMeterExampleAi.Pro.available?() do
    defp uncertain_recovery(_ctx, _item) do
      %{
        needed: true,
        command: """
        Read at the provider FIRST, with a read-only call:

            stripe events list --limit 20
            stripe billing meter_event_summaries list --meter <mtr_...> \\
              --customer <cus_...> --start-time <t> --end-time <t>

        Then record what you found, with the state you expect to find:

            AuroraMeter.Pro.Recovery.acknowledge_item(item_id,
              expected: %{state: "uncertain", lease_token: token,
                          subject_ref: subject, provider_ref: "mev_..."},
              reason: "confirmed at the provider",
              evidence: "meter event summary shows the quantity for this window")

        or, if you can show it did NOT land:

            AuroraMeter.Pro.Recovery.abandon_item(item_id,
              expected: %{state: "uncertain", lease_token: token, subject_ref: subject},
              reason: "not present at the provider",
              evidence: "...")

        Both refuse if the item has moved since you read it, both write an
        `aurora_meter_recovery_actions` row recording the decision and what you
        believed, and neither has a `force:` option.
        """,
        ran: false,
        note: "the sample's own teaching outbox has no equivalent; see below"
      }
    end
  else
    defp uncertain_recovery(_ctx, item) do
      %{
        needed: true,
        command: """
        The core profile has no guarded recovery operation, and this recipe says
        so rather than printing a row edit.

        What the free path gives you is the FACT: the item is `uncertain`, it is
        visible on /ops with its age, and nothing will retry it behind your back.
        What it does not give you is a mechanism for recording a decision about
        it. The commercial tier's `AuroraMeter.Pro.Recovery` is that mechanism:
        an `expected:` map, a reason, evidence, an audit row, and no `force:`.

        Item #{item.id} is where the decision would be recorded.
        """,
        ran: false,
        note:
          "a row edit would be the obvious thing to print here and it is exactly what 04e " <>
            "removed from Pro's own recovery documentation. L09d-4 forbids it and a test " <>
            "enforces the absence of UPDATE, INSERT and DELETE in docs/failures.md"
      }
    end
  end

  defp report(ctx, fields) do
    # (kept here so both branches above share it)
    Map.merge(fields, %{
      profile: AuroraMeterExampleAi.Pro.profile(),
      tenant: ctx.org.slug,
      tenant_key: ctx.tenant_key,
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })
  end
end
