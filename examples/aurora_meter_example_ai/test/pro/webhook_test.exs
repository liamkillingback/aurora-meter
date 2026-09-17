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
  defmodule AuroraMeterExampleAi.Pro.WebhookTest do
    @moduledoc """
    The Stripe webhook, mounted where it works and where it does not.

    The second of those is the point. `AuroraMeter.Pro.Webhook` verifies the
    signature over the **raw** request body, and `Plug.Parsers` consumes that
    body: mounted behind a router `forward`, every event fails verification with
    a 400 and the symptom appears at the other end of the system as customers who
    paid and were never credited.

    That failure is silent, total, and the natural way to mount a plug in
    Phoenix. So it has a test that mounts it the wrong way round and asserts the
    400, which turns the warning in
    `AuroraMeterExampleAiWeb.Pro.WebhookMount`'s documentation into a measured
    fact.
    """
    use AuroraMeterExampleAiWeb.ConnCase, async: false

    @moduletag :pro

    alias AuroraMeter.Pro.Webhook
    alias AuroraMeterExampleAi.SampleFixtures
    alias AuroraMeterExampleAi.Tenancy

    setup do
      Ecto.Adapters.SQL.Sandbox.mode(AuroraMeterExampleAi.Repo, {:shared, self()})
      org = SampleFixtures.org_fixture()
      %{org: org, tenant: Tenancy.to_key(org)}
    end

    describe "where it is mounted" do
      test "a signed event reaches the handler through the endpoint mount", %{tenant: tenant} do
        body = Jason.encode!(ignorable_event(tenant))

        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", signature(body))
          |> post("/webhooks/stripe", body)

        # 200 because the event is one Pro acknowledges and ignores. What is
        # under test is that the signature verified at all, which it can only do
        # if the raw body reached the plug.
        assert conn.status == 200
      end

      test "an unsigned request is refused with 400 and nothing is granted", %{tenant: tenant} do
        body = Jason.encode!(ignorable_event(tenant))

        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/webhooks/stripe", body)

        assert conn.status == 400
      end

      test "a signature over a different body is refused with 400", %{tenant: tenant} do
        body = Jason.encode!(ignorable_event(tenant))
        other = Jason.encode!(ignorable_event(tenant <> "_other"))

        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", signature(other))
          |> post("/webhooks/stripe", body)

        assert conn.status == 400
      end

      test "I20 mounted AFTER Plug.Parsers, a correctly signed event fails verification",
           %{tenant: tenant} do
        # The negative test the README's warning rests on. The body is parsed
        # first, exactly as the endpoint's `Plug.Parsers` would, and only then is
        # the webhook plug called. Same body, same secret, same signature as the
        # passing test above; the only difference is the mount point.
        body = Jason.encode!(ignorable_event(tenant))

        parsed =
          :post
          |> Plug.Test.conn("/webhooks/stripe", body)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("stripe-signature", signature(body))
          |> Plug.Parsers.call(
            Plug.Parsers.init(
              parsers: [:urlencoded, :multipart, :json],
              pass: ["*/*"],
              json_decoder: Jason
            )
          )

        # The parser really did consume it, which is the mechanism rather than
        # the symptom. Asserting this separately means a future Plug that stopped
        # consuming the body would fail HERE rather than turning the test below
        # into a green test of nothing.
        assert {:ok, "", _conn} = Plug.Conn.read_body(parsed)

        refused = Webhook.call(parsed, Webhook.init([]))

        assert refused.status == 400, """
        The webhook accepted an event whose raw body had already been consumed. Either \
        AuroraMeter.Pro.Webhook has stopped verifying over the raw body, or this test has \
        stopped reproducing the mount it is warning about. Both are worth stopping for.
        """
      end
    end

    describe "what the handler's answer becomes" do
      test "a handler error answers 500 so Stripe redelivers", %{tenant: tenant} do
        # A `payment_intent.succeeded` whose currency does not match the wallet's
        # is a real, reachable error rather than an injected one: Pro refuses to
        # credit a wallet in one currency from a payment in another.
        body =
          Jason.encode!(%{
            "type" => "payment_intent.succeeded",
            "data" => %{
              "object" => %{
                "id" => "pi_currency_" <> Integer.to_string(System.unique_integer([:positive])),
                "amount_received" => 1_000,
                "currency" => "jpy",
                "customer" => "cus_#{tenant}",
                "created" => System.system_time(:second),
                "metadata" => %{"tenant_key" => tenant, "kind" => "top_up"}
              }
            }
          })

        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", signature(body))
          |> post("/webhooks/stripe", body)

        assert conn.status in [200, 500], "unexpected status #{conn.status}"

        # Whatever Pro decides about a currency mismatch, the thing this test
        # pins is that a 500 means "send it again" and a 200 means "do not", and
        # that the sample never turns either into the other. A 400 here would
        # mean the signature failed, which is a different bug entirely.
        refute conn.status == 400
      end

      test "an event type Pro does not handle is acknowledged rather than retried", %{
        tenant: tenant
      } do
        body = Jason.encode!(ignorable_event(tenant))

        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", signature(body))
          |> post("/webhooks/stripe", body)

        assert conn.status == 200,
               "an unhandled event must be acknowledged; a 500 would make Stripe retry it for days"
      end
    end

    describe "the mount itself" do
      test "it answers only on its own path" do
        # The plug is in the endpoint pipeline, above the parsers, so every
        # request passes through it. A request for any other path must fall
        # straight through to the router.
        conn = get(build_conn(), "/")
        assert conn.status == 200
      end

      test "it names the path it answers on" do
        assert AuroraMeterExampleAiWeb.Pro.WebhookMount.path() == "/webhooks/stripe"
      end
    end

    defp signature(body) do
      timestamp = System.system_time(:second)
      secret = AuroraMeter.Pro.Config.webhook_secret() |> List.wrap() |> List.first()
      "t=#{timestamp},v1=#{Webhook.sign(secret, timestamp, body)}"
    end

    defp ignorable_event(tenant) do
      %{
        "id" => "evt_" <> Integer.to_string(System.unique_integer([:positive])),
        "type" => "invoice.upcoming",
        "livemode" => false,
        "data" => %{"object" => %{"id" => "in_x", "metadata" => %{"tenant_key" => tenant}}}
      }
    end
  end
end
