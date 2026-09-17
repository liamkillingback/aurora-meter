# The whole module is behind the compile-time guard, and it has to be.
#
# ExUnit loads every `*_test.exs` under `test/`, so in the core profile these
# files are COMPILED even though their `:pro` tag excludes them from running.
# They name `AuroraMeter.Pro.Credits.StripeClient.Fake` and half a dozen other
# modules that are not in a core-profile build, and the compiler says so, once
# per call site, on every run of the free suite. `mix compile
# --warnings-as-errors` then fails a suite that is entirely green.
#
# An excluded test that still warns is worse than a skipped one: it is noise a
# reader learns to scroll past, in the one profile where nothing should be
# unusual. `test/test_helper.exs` prints the loud skip instead, naming the
# files and how to run them.
if Code.ensure_loaded?(AuroraMeter.Pro) do
  defmodule AuroraMeterExampleAi.Pro.BillingTest do
    @moduledoc """
    The Pro profile, against Aurora Meter Pro's own provider fakes.

    Every test here is tagged `:pro` and the suite excludes that tag when the
    package is not in the build, **loudly**: `test/test_helper.exs` prints the
    count and the reason, because a required suite that is silently skipped
    reports as a pass and is worth nothing (RUN01, applied at the test level).

    These are the criteria build unit 09d owes for task 09.07, and they are the
    four that involve money: one grant per payment, one reversal per refund, a
    retry that cannot change what is delivered, and a race that produces two
    distinct grants rather than one doubled one.
    """
    use AuroraMeterExampleAiWeb.ConnCase, async: false
    use AuroraMeter.Test, reset: true

    import Phoenix.LiveViewTest

    @moduletag :pro

    alias AuroraMeter.Credits
    alias AuroraMeter.Pro.Credits.StripeClient.Fake
    alias AuroraMeterExampleAi.SampleFixtures
    alias AuroraMeterExampleAi.Tenancy

    setup do
      # Shared mode, because two of these tests deliver the same event from two
      # `Task`s at once and a webhook handler takes an advisory lock on its own
      # connection.
      Ecto.Adapters.SQL.Sandbox.mode(AuroraMeterExampleAi.Repo, {:shared, self()})
      org = SampleFixtures.org_fixture()
      %{org: org, tenant: Tenancy.to_key(org)}
    end

    describe "a payment grants once" do
      test "I14 two deliveries of one payment_intent.succeeded grant once", %{
        org: org,
        tenant: tenant
      } do
        event = succeeded(tenant, "pi_" <> unique(), 2_500)

        before = Credits.summary(org)

        assert {:ok, _} = AuroraMeter.Pro.Credits.handle_event(event)
        after_first = Credits.summary(org)

        # The same event again, byte for byte, as Stripe sends it when an
        # acknowledgement is lost.
        assert {:ok, _} = AuroraMeter.Pro.Credits.handle_event(event)
        after_second = Credits.summary(org)

        assert after_first.balance - before.balance == 25_000_000,
               "2500 cents is 25 USD, which is 25_000_000 micro-USD"

        assert after_second.balance == after_first.balance,
               "the second delivery granted again: #{after_second.balance} vs #{after_first.balance}"

        grants = grants_for(org)
        assert length(grants) == 1, "one payment, one ledger entry, got #{length(grants)}"
      end

      test "I14 two deliveries racing from independent processes still grant once", %{
        org: org,
        tenant: tenant
      } do
        # Sequential replay proves idempotence against a redelivery. It does not
        # prove it against two deliveries in flight at once, which is what
        # actually happens when a provider retries before the first answer
        # arrives. Two tasks, one event, one grant.
        event = succeeded(tenant, "pi_" <> unique(), 1_000)
        before = Credits.summary(org)

        results =
          [1, 2]
          |> Enum.map(fn _ ->
            Task.async(fn -> AuroraMeter.Pro.Credits.handle_event(event) end)
          end)
          |> Task.await_many(10_000)

        assert Enum.all?(results, &match?({:ok, _}, &1)),
               "both deliveries must be accepted, got #{inspect(results)}"

        assert Credits.summary(org).balance - before.balance == 10_000_000
        assert length(grants_for(org)) == 1
      end
    end

    describe "a refund reverses once" do
      test "I13 one refund reverses once and a redelivered refund reverses nothing further", %{
        org: org,
        tenant: tenant
      } do
        intent = "pi_" <> unique()
        charge = "ch_" <> unique()

        assert {:ok, _} = AuroraMeter.Pro.Credits.handle_event(succeeded(tenant, intent, 2_500))
        granted = Credits.summary(org)

        # The charge has to exist at the provider, because Pro reads it back
        # rather than trusting the event's snapshot: a refund event is a
        # notification and the charge is the record. Without this the handler
        # answers `{:error, :not_found}`, which is the right answer to "reverse a
        # charge I have never heard of" and is how this line came to be here.
        Fake.put_charge(
          charge,
          {:ok,
           %{
             id: charge,
             payment_intent: intent,
             currency: "usd",
             amount_refunded: 1_000,
             refunded: false,
             disputes: []
           }}
        )

        # `metadata.tenant_key` on the CHARGE, because that is where Pro looks:
        # Stripe copies a PaymentIntent's metadata onto the charge, and a charge
        # that does not say whose it is cannot be placed against a wallet.
        #
        # The first version of this test left it off. The refund then took the
        # "unidentified" branch, answered 200, opened a `reversal_without_grant`
        # reconciliation item and reversed nothing, and the test still passed,
        # because its assertions were about what did NOT happen. A test of "one
        # reversal" that passes on zero reversals is the exact shape this
        # programme keeps finding, so the assertion below now requires the
        # reversal rather than tolerating its absence.
        refund = charge_refunded(charge, intent, 1_000, tenant)

        first = AuroraMeter.Pro.Credits.handle_event(refund)
        after_first = Credits.summary(org)

        second = AuroraMeter.Pro.Credits.handle_event(refund)
        after_second = Credits.summary(org)

        assert match?({:ok, _}, first), "the refund was not applied: #{inspect(first)}"

        assert granted.balance - after_first.balance == 10_000_000,
               "the reversal must be 1000 cents and nothing else"

        assert after_second.balance == after_first.balance,
               "a redelivered refund moved the balance again: #{inspect({first, second})}"

        assert after_second.debt == after_first.debt

        reversals = reversals_for(org)

        assert length(reversals) == 1,
               "one refund must produce exactly one reversal entry, got #{length(reversals)}"

        # And the lot it came out of. The paid lot funded the grant, so the paid
        # lot is what the reversal takes back, and it takes it back once.
        lots = Credits.Lots.list(org, states: :all, limit: 20)
        paid = Enum.filter(lots, &(&1.category == :paid))

        assert Enum.sum(Enum.map(paid, & &1.reversed)) == 10_000_000,
               "the reversal came out of somewhere other than the paid lot: #{inspect(lots)}"
      end
    end

    describe "a retried delivery carries what was staged" do
      test "I15 changing the org's plan between an enqueue and its retry does not change the payload",
           %{org: org, tenant: tenant} do
        # Record on one plan.
        id = "gen:" <> Ecto.UUID.generate()

        {:ok, _event, :inserted} =
          AuroraMeter.record(org, :tokens, 40,
            id: id,
            occurred_at: DateTime.utc_now(),
            dimensions: %{"model" => "nimbus-1-mini", "kind" => "text"}
          )

        staged = pro_item!(tenant, id)
        payload_before = staged.payload

        # Change the plan underneath it. The subscription moves; the staged item
        # must not, because it is a record of what was true when the fact
        # happened and not a query re-run at delivery time.
        AuroraMeter.subscribe(org, :free)

        staged_after = pro_item!(tenant, id)

        assert staged_after.payload == payload_before,
               "the staged payload changed when the plan did"

        assert staged_after.id == staged.id
      end
    end

    describe "auto-recharge and a manual top-up" do
      test "I11 two payments in flight at once produce two distinct grants and no double spend",
           %{
             org: org,
             tenant: tenant
           } do
        manual = succeeded(tenant, "pi_manual_" <> unique(), 1_000)
        automatic = succeeded(tenant, "pi_auto_" <> unique(), 2_500, "auto_top_up")

        before = Credits.summary(org)

        results =
          [manual, automatic]
          |> Enum.map(fn event ->
            Task.async(fn -> AuroraMeter.Pro.Credits.handle_event(event) end)
          end)
          |> Task.await_many(10_000)

        assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)

        after_both = Credits.summary(org)

        assert after_both.balance - before.balance == 35_000_000,
               "10 USD and 25 USD is 35 USD, and neither may be lost or doubled"

        grants = grants_for(org)
        assert length(grants) == 2, "two payments, two grants, got #{length(grants)}"

        references = grants |> Enum.map(& &1.reference) |> Enum.uniq()
        assert length(references) == 2, "the two grants share a reference: #{inspect(references)}"
      end
    end

    describe "the /billing page" do
      test "it renders the subscription, the credit account and the auto-recharge settings",
           %{conn: _} = context do
        %{conn: conn} = log_in_org_owner(context)

        {:ok, _view, html} = live(conn, "/billing")

        assert html =~ "Subscription"
        assert html =~ "Credit"
        assert html =~ "Auto-recharge"
        assert html =~ "Top up"
        assert html =~ "studio"

        # And the sentence that keeps it honest.
        assert html =~ "when the webhook reports the payment"
      end

      test "the success return says the webhook grants, not the redirect",
           %{conn: _} = context do
        %{conn: conn} = log_in_org_owner(context)

        {:ok, _view, html} = live(conn, "/billing?checkout=success")

        assert html =~ "Stripe reported the checkout session complete"
        assert html =~ "Credit is granted when the webhook arrives"
        refute html =~ "Payment successful"
        refute html =~ "Thank you for your payment"
      end
    end

    ## helpers

    defp unique, do: Integer.to_string(System.unique_integer([:positive]))

    defp succeeded(tenant, intent, cents, kind \\ "top_up") do
      %{
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => intent,
            "amount_received" => cents,
            "currency" => "usd",
            "customer" => "cus_#{tenant}",
            "payment_method" => "pm_#{tenant}",
            "created" => System.system_time(:second),
            "metadata" => %{"tenant_key" => tenant, "kind" => kind}
          }
        }
      }
    end

    defp charge_refunded(charge_id, intent_id, cents, tenant) do
      %{
        "type" => "charge.refunded",
        "data" => %{
          "object" => %{
            "id" => charge_id,
            "payment_intent" => intent_id,
            "amount_refunded" => cents,
            "currency" => "usd",
            "created" => System.system_time(:second),
            # Stripe copies the PaymentIntent's metadata onto the charge, and Pro
            # reads the tenant from here rather than from a global lookup by
            # grant reference. Without it the reversal cannot be placed.
            "metadata" => %{"tenant_key" => tenant, "kind" => "top_up"}
          }
        }
      }
    end

    # Read through the public history, never by querying an aurora_meter table.
    defp grants_for(org) do
      org
      |> Credits.history(kinds: [:grant], limit: 100)
      |> Enum.filter(&(&1.amount > 0))
    end

    defp reversals_for(org) do
      Credits.history(org, kinds: [:reverse], limit: 100)
    end

    # The one place this suite looks at a Pro-owned table, and it is a read in a
    # test rather than in the application: `lib/` never does this.
    defp pro_item!(tenant_key, subject_ref) do
      import Ecto.Query

      item =
        AuroraMeterExampleAi.Repo.one(
          from(i in "aurora_meter_outbox_items",
            where: i.tenant_key == ^tenant_key and i.subject_ref == ^subject_ref,
            select: %{id: i.id, payload: i.payload, state: i.state}
          )
        )

      assert item != nil,
             "no Pro outbox item was staged for #{subject_ref}; the composite outbox did not run"

      item
    end
  end
end
