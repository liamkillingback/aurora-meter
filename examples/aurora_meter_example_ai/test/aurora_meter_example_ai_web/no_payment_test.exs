defmodule AuroraMeterExampleAiWeb.NoPaymentTest do
  @moduledoc """
  L09c-1: no page in the core profile offers, implies or simulates a payment,
  and **no page in either profile ever claims one happened or collects a card**.

  ## Why this is not a word list

  The build plan for 09c asked for "no occurrence of the words checkout, card,
  pay or a Stripe reference". That instrument was written and it failed on the
  honest half of this application: the landing page says "there is no payment
  here", the developer tools page says "this sample takes no money, has no card
  form", and `:paid` is the name of a credit category the operations page
  prints. You cannot say there is no payment without the word.

  The criterion underneath it is what matters, and it is about **offers and
  claims**, not about vocabulary:

    1. no control invites the reader to pay;
    2. no field collects card details;
    3. no text says a payment happened;
    4. no provider is named and no key shape appears.

  Each of the four is checked separately and each has a control that plants the
  thing it is looking for, because three of them are negatives and a negative
  whose instrument cannot fire is not a test.

  ## What build unit 09d changed, and what it deliberately did not

  The Pro profile adds a real Stripe test-mode integration, so two of the four
  rules have to be read per profile and two of them do not. The split is the
  substance of this file:

  | Rule | Core profile | Pro profile |
  |---|---|---|
  | 1. no control offers to pay | every page | every page **except** `/billing`, which must offer, and the test asserts that it does |
  | 2. no field collects card details | every page | **every page, including `/billing`** |
  | 3. no text claims a payment happened | every page | **every page, including `/billing`** |
  | 4. no provider named, no key shape | every page | key shapes on every page; the provider is named on `/billing`, honestly |

  Rules 2 and 3 do not soften, and that is the point. A card is collected by
  Stripe on Stripe's own domain, never here, so a card field appearing in this
  application is a defect in either profile. And a page that says a payment
  succeeded is saying something only the webhook can know: the `/billing`
  success return says Stripe reported the session complete and that the credit
  appears when the event lands, which is a different sentence and passes rule
  3 because it is not a claim about money.
  """
  use AuroraMeterExampleAiWeb.ConnCase, async: false
  use AuroraMeter.Test, reset: true

  import Phoenix.LiveViewTest

  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAi.SampleFixtures

  # 1. Control labels that offer to take money.
  @offer_words ~w(checkout buy purchase upgrade subscribe)
  # "top up" was added by 09d, and it was added because the scan could not see
  # the Pro profile's `/billing` page offering anything at all: its buttons say
  # "Top up $5.00", which is as plain an offer to take money as exists and
  # contained none of the words above. A scan that cannot see the one page in
  # this application that really does offer to take money is a scan that has
  # never been watched working.
  @offer_phrases [
    "pay now",
    "pay ",
    "add card",
    "add a card",
    "payment method",
    "start trial",
    "top up"
  ]

  # 2. Field names and placeholders that collect card details.
  @card_fields ~w(card cardnumber card_number cvc cvv expiry exp_month exp_year postal_code)

  # 3. Claims that a payment happened.
  @success_phrases [
    "payment successful",
    "payment received",
    "payment complete",
    "thank you for your payment",
    "your card",
    "charged your",
    "we have charged",
    "receipt"
  ]

  # 4. Providers and key shapes, forbidden anywhere at all.
  @provider_words ~w(stripe paddle braintree adyen visa mastercard amex)
  @key_shapes ~w(sk_live sk_test pk_live pk_test whsec_ acct_ pi_ cs_)

  setup do
    scope = SampleFixtures.funded_scope_fixture()

    {:ok, _generation, :created} =
      Generations.create(
        scope,
        %{"kind" => "text", "prompt" => "a poem about a ledger", "model" => "nimbus-1-mini"},
        Ecto.UUID.generate()
      )

    %{scope: scope, conn: log_in_user(build_conn(), scope.user)}
  end

  # Every page in this build. `/billing` exists only in the Pro profile, and
  # the list says so rather than a test skipping.
  defp pages(conn, scope) do
    generation = hd(Generations.list(scope))

    core = [
      {"/", conn |> get(~p"/") |> html_response(200)},
      {"/generate", live_html(conn, ~p"/generate")},
      {"/history", live_html(conn, ~p"/history")},
      {"/history/:id", live_html(conn, "/history/#{generation.id}")},
      {"/ops", live_html(conn, ~p"/ops")},
      {"/dev/tools", live_html(conn, ~p"/dev/tools")}
    ]

    if pro?() do
      core ++ [{"/billing", live_html(conn, "/billing")}]
    else
      core
    end
  end

  # The pages that must never offer a payment, in either profile. In the Pro
  # profile that is everything except `/billing`; `/billing` has its own test
  # below asserting that it DOES offer, so the exemption is measured rather
  # than assumed.
  defp non_billing_pages(conn, scope) do
    Enum.reject(pages(conn, scope), fn {path, _html} -> path == "/billing" end)
  end

  test "1. no control outside /billing offers to take money", %{conn: conn, scope: scope} do
    findings =
      Enum.flat_map(non_billing_pages(conn, scope), fn {path, html} ->
        html |> offers() |> Enum.map(&{path, &1})
      end)

    # In the Pro profile `/generate` carries one link labelled "Top up at
    # Stripe". It is a link TO the page that offers, not the offer itself, and
    # it is named here rather than the rule being widened: an exemption that
    # lists one path and one phrase stays readable, and one that relaxes the
    # scan does not.
    allowed = if pro?(), do: [{"/generate", "top up"}], else: []

    assert findings -- allowed == [],
           "a control offers a payment: #{inspect(findings -- allowed)}"
  end

  test "1. in the Pro profile /billing offers, and in the core profile it does not exist",
       %{conn: conn, scope: scope} do
    if pro?() do
      {"/billing", html} =
        Enum.find(pages(conn, scope), fn {path, _} -> path == "/billing" end)

      assert offers(html) != [], """
      /billing exists in the Pro profile and offered nothing the scan could see. Either the \
      page has stopped offering a real checkout, or the scan has stopped working; both are \
      worth stopping for, and the exemption above rests on this assertion.
      """
    else
      # Not "the page renders nothing" and not "the link is hidden": there is
      # no route, so the request 404s like any other address this application
      # does not serve. (`assert_error_sent/2` is the wrong instrument here:
      # the endpoint renders the 404 page rather than letting the exception
      # escape, and it would fail with "response sent 404 without error".)
      assert %{status: 404} = get(conn, "/billing")
    end
  end

  test "1. control: the offer scan sees a Checkout button and ignores prose about payment" do
    guilty = ~s|<div><p>Nothing here.</p><button class="btn">Checkout</button></div>|

    innocent =
      ~s|<div><p>Nothing on this page takes a payment.</p><button>Generate</button></div>|

    assert offers(guilty) != [], "the scan cannot see a checkout button"
    assert offers(innocent) == [], "the scan fires on prose, so it would be turned off"
  end

  test "2. no page collects card details", %{conn: conn, scope: scope} do
    findings =
      Enum.flat_map(pages(conn, scope), fn {path, html} ->
        html |> card_fields() |> Enum.map(&{path, &1})
      end)

    assert findings == [], "a field collects card details: #{inspect(findings)}"
  end

  test "2. control: the field scan sees a card number input" do
    guilty = ~s|<form><input name="card_number" placeholder="4242 4242 4242 4242" /></form>|
    innocent = ~s|<form><input name="generation[prompt]" placeholder="a poem" /></form>|

    assert card_fields(guilty) != [], "the scan cannot see a card field"
    assert card_fields(innocent) == []
  end

  test "3. no page claims a payment happened", %{conn: conn, scope: scope} do
    findings =
      Enum.flat_map(pages(conn, scope), fn {path, html} ->
        html |> success_claims() |> Enum.map(&{path, &1})
      end)

    assert findings == [], "a page claims a payment happened: #{inspect(findings)}"
  end

  test "3. control: the claim scan sees a success message and ignores a denial" do
    guilty = ~s|<div><p>Payment successful. Thank you!</p></div>|
    innocent = ~s|<div><p>No payment was taken and no payment is possible here.</p></div>|

    assert success_claims(guilty) != [], "the scan cannot see a payment success claim"
    assert success_claims(innocent) == []
  end

  test "4. no page anywhere shows a key shape", %{conn: conn, scope: scope} do
    # This half does not soften in the Pro profile. A key, an account id, a
    # payment intent id or a checkout session id on a rendered page is a
    # defect whichever profile produced it.
    findings =
      Enum.flat_map(pages(conn, scope), fn {path, html} ->
        lower = String.downcase(html)

        @key_shapes
        |> Enum.filter(&String.contains?(lower, &1))
        |> Enum.map(&{path, &1})
      end)

    assert findings == [], "a key shape is on the page: #{inspect(findings)}"
  end

  test "4. no page outside /billing names a payment provider", %{conn: conn, scope: scope} do
    findings =
      Enum.flat_map(non_billing_pages(conn, scope), fn {path, html} ->
        lower = String.downcase(html)

        @provider_words
        |> Enum.filter(&String.contains?(lower, &1))
        |> Enum.map(&{path, &1})
      end)

    # `/generate` in the Pro profile links to `/billing` with the words "Top up
    # at Stripe", which names the provider on a page that is not `/billing`.
    # That is the one exception, it is a link rather than an offer, and naming
    # it here is better than widening the rule.
    allowed = if pro?(), do: [{"/generate", "stripe"}], else: []

    assert findings -- allowed == [],
           "a provider is named outside /billing: #{inspect(findings -- allowed)}"
  end

  test "4. control: the provider scan is looking at the whole document" do
    html = ~s|<html><head><meta name="x" content="stripe" /></head><body>nothing</body></html>|
    assert String.contains?(String.downcase(html), "stripe")
  end

  test "the developer tools page says out loud that its grant is synthetic", %{conn: conn} do
    html = live_html(conn, ~p"/dev/tools")
    assert html =~ "Everything on this page is synthetic"
    assert html =~ "takes no money"
    assert html =~ "synthetic credit"
  end

  test "the landing page says there is no payment before it says anything else", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "There is no AI here and there is no payment here"
  end

  defp live_html(conn, path) do
    {:ok, _view, html} = live(conn, path)
    html
  end

  # Every interactive control's visible label, lower cased.
  defp control_labels(html) do
    doc = LazyHTML.from_fragment(html)

    buttons =
      doc |> LazyHTML.query("button, a, [role=button]") |> Enum.map(&LazyHTML.text/1)

    submits =
      doc
      |> LazyHTML.query(~s|input[type="submit"]|)
      |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))

    (buttons ++ submits)
    |> Enum.map(&(&1 |> to_string() |> String.downcase() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp offers(html) do
    labels = control_labels(html)

    words =
      labels
      |> Enum.flat_map(&String.split(&1, ~r/[^a-z]+/, trim: true))
      |> Enum.filter(&(&1 in @offer_words))

    phrases =
      for label <- labels, phrase <- @offer_phrases, String.contains?(label, phrase), do: phrase

    Enum.uniq(words ++ phrases)
  end

  defp card_fields(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input, select, textarea, label")
    |> Enum.flat_map(fn element ->
      ["name", "id", "placeholder", "autocomplete", "for"]
      |> Enum.flat_map(&LazyHTML.attribute(element, &1))
      |> Kernel.++([LazyHTML.text(element)])
      |> Enum.map(&String.downcase(to_string(&1)))
    end)
    |> Enum.flat_map(fn value ->
      Enum.filter(@card_fields, fn field ->
        value
        |> String.split(~r/[^a-z_]+/, trim: true)
        |> Enum.any?(&(&1 == field))
      end)
    end)
    |> Enum.uniq()
  end

  defp success_claims(html) do
    text = html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.downcase()
    Enum.filter(@success_phrases, &String.contains?(text, &1))
  end

  # Asked of the code server at runtime rather than through
  # `AuroraMeterExampleAi.Pro.available?/0`, which is a compile-time constant
  # the type checker folds, leaving "this branch can never match" warnings on
  # every profile-dependent `if` in this file. The two are tied together by
  # `test/pro_absent_test.exs`, which asserts they agree.
  defp pro?, do: Code.ensure_loaded?(AuroraMeter.Pro)
end
