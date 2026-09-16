defmodule AuroraMeterExampleAiWeb.NoPaymentTest do
  @moduledoc """
  L09c-1: no page in the core profile offers, implies or simulates a payment.

  ## Why this is not a word list

  The build plan for this unit asked for "no occurrence of the words checkout,
  card, pay or a Stripe reference". That instrument was written and it failed
  on the honest half of this application: the landing page says "there is no
  payment here", the developer tools page says "this sample takes no money, has
  no card form", and `:paid` is the name of a credit category the operations
  page prints. You cannot say there is no payment without the word.

  The criterion underneath it is what matters, and it is about **offers and
  claims**, not about vocabulary:

    1. no control anywhere invites the reader to pay;
    2. no field anywhere collects card details;
    3. no text anywhere says a payment happened;
    4. no provider is named and no key shape appears.

  Each of the four is checked separately and each has a control that plants the
  thing it is looking for, because three of them are negatives and a negative
  whose instrument cannot fire is not a test.
  """
  use AuroraMeterExampleAiWeb.ConnCase, async: false
  use AuroraMeter.Test, reset: true

  import Phoenix.LiveViewTest

  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAi.SampleFixtures

  # 1. Control labels that offer to take money.
  @offer_words ~w(checkout buy purchase upgrade subscribe)
  @offer_phrases ["pay now", "pay ", "add card", "add a card", "payment method", "start trial"]

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

  defp pages(conn, scope) do
    generation = hd(Generations.list(scope))

    [
      {"/", conn |> get(~p"/") |> html_response(200)},
      {"/generate", live_html(conn, ~p"/generate")},
      {"/history", live_html(conn, ~p"/history")},
      {"/history/:id", live_html(conn, "/history/#{generation.id}")},
      {"/ops", live_html(conn, ~p"/ops")},
      {"/dev/tools", live_html(conn, ~p"/dev/tools")}
    ]
  end

  test "1. no control on any page offers to take money", %{conn: conn, scope: scope} do
    findings =
      Enum.flat_map(pages(conn, scope), fn {path, html} ->
        html |> offers() |> Enum.map(&{path, &1})
      end)

    assert findings == [], "a control offers a payment: #{inspect(findings)}"
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

  test "4. no page names a provider or shows a key shape", %{conn: conn, scope: scope} do
    findings =
      Enum.flat_map(pages(conn, scope), fn {path, html} ->
        lower = String.downcase(html)

        Enum.filter(@provider_words ++ @key_shapes, &String.contains?(lower, &1))
        |> Enum.map(&{path, &1})
      end)

    assert findings == [], "a provider or a key shape is on the page: #{inspect(findings)}"
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
end
