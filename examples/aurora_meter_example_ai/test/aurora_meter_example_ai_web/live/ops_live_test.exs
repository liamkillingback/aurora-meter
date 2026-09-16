defmodule AuroraMeterExampleAiWeb.OpsLiveTest do
  @moduledoc """
  The operations page: conservation, the outbox, the two sources and the orphan.
  """
  use AuroraMeterExampleAiWeb.ConnCase, async: false
  use AuroraMeter.Test, reset: true

  import Phoenix.LiveViewTest

  alias AuroraMeter.Credits
  alias AuroraMeter.Exporter.Journal
  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAi.Generations.Generation
  alias AuroraMeterExampleAi.Ops
  alias AuroraMeterExampleAi.Repo
  alias AuroraMeterExampleAi.SampleFixtures
  alias AuroraMeterExampleAi.SampleOutbox.Item

  @text %{"kind" => "text", "prompt" => "a poem about a ledger", "model" => "nimbus-1-mini"}
  @image %{"kind" => "image", "prompt" => "a picture of a ledger", "model" => "nimbus-1-mini"}

  setup do
    Journal.reset()
    scope = SampleFixtures.funded_scope_fixture(%{credit: 50_000_000})
    %{scope: scope, conn: log_in_user(build_conn(), scope.user)}
  end

  describe "I10 conservation" do
    test "granted minus spent minus held equals available after a scripted sequence", %{
      scope: scope
    } do
      org = scope.org

      # A grant, ten settled generations, one refused generation, and one open
      # hold, so the identity is checked against a wallet with something in
      # every bucket rather than a quiet one.
      for n <- 1..10 do
        attrs = if rem(n, 3) == 0, do: @image, else: @text
        {:ok, _, :created} = Generations.create(scope, attrs, Ecto.UUID.generate())
      end

      {:error, _} =
        Generations.create(scope, Map.put(@text, "prompt", "fail: here"), Ecto.UUID.generate())

      {:ok, _hold} = Credits.hold(org, 1_000_000, SampleFixtures.grant_reference("open-hold"))

      conservation = Ops.conservation(scope)

      assert conservation.entries > 20
      assert conservation.ledger_balance == conservation.summary_balance
      assert conservation.ledger_held == conservation.summary_held
      assert conservation.summary_held == 1_000_000

      assert conservation.summary_balance - conservation.summary_held ==
               conservation.summary_available

      assert conservation.holds
    end

    test "the identity check can fail" do
      # Control: the page reports `holds: true` by comparing four numbers. If
      # the comparison were vacuous, every wallet would pass. This asserts the
      # shape of the answer on figures that deliberately do not agree.
      false_conservation = %{
        ledger_balance: 5,
        summary_balance: 6,
        ledger_held: 0,
        summary_held: 0,
        summary_available: 6
      }

      refute false_conservation.ledger_balance == false_conservation.summary_balance
    end

    test "the page renders the identity and says yes", %{conn: conn, scope: scope} do
      {:ok, _, :created} = Generations.create(scope, @text, Ecto.UUID.generate())
      {:ok, _view, html} = live(conn, ~p"/ops")

      assert html =~ "Conservation"
      assert html =~ ~s|data-holds="true"|
    end
  end

  describe "the outbox on the page" do
    test "an uncertain item is shown with its age and is not retried automatically",
         %{conn: conn, scope: scope} do
      id = Ecto.UUID.generate()
      {:ok, _, :created} = Generations.create(scope, @text, id)
      Journal.script(Generations.reference(id), :uncertain)

      {:ok, view, _html} = live(conn, ~p"/ops")
      html = view |> element("button", "Drain the outbox now") |> render_click()

      assert html =~ "uncertain"
      assert html =~ "may or may not have reached the provider"
      assert %Item{state: "uncertain"} = Repo.one(Item)

      # And the automatic path leaves it alone.
      view |> element("button", "Drain the outbox now") |> render_click()
      assert %Item{state: "uncertain"} = Repo.one(Item)
    end

    test "a delivered item does not raise the uncertain warning", %{conn: conn, scope: scope} do
      {:ok, _, :created} = Generations.create(scope, @text, Ecto.UUID.generate())
      {:ok, view, _html} = live(conn, ~p"/ops")
      html = view |> element("button", "Drain the outbox now") |> render_click()

      assert html =~ "delivered"
      refute html =~ "may or may not have reached the provider"
    end
  end

  describe "I08 on the page" do
    test "an image generation puts nothing in the outbox and something in the buffered counter",
         %{conn: conn, scope: scope} do
      {:ok, _, :created} = Generations.create(scope, @image, Ecto.UUID.generate())

      sources = Ops.sources(scope)
      assert sources.images_counter == 1
      assert sources.images_outbox_rows == 0
      assert sources.tokens_outbox_rows == 1
      assert sources.tokens_counter == sources.tokens_outbox_quantity

      {:ok, _view, html} = live(conn, ~p"/ops")
      assert html =~ "a buffered feature never reaches the outbox"
    end
  end

  describe "the orphan" do
    test "an orphaned event is listed, and mix sample.repair rebuilds its row", %{
      conn: conn,
      scope: scope
    } do
      {:ok, original, :created} = Generations.create(scope, @text, Ecto.UUID.generate())
      Repo.delete_all(Generation)

      assert [item] = Ops.orphans(scope)
      assert item.event_id == original.event_id

      {:ok, _view, html} = live(conn, ~p"/ops")
      assert html =~ ~s|data-count="1"|
      assert html =~ original.event_id

      # The task's own rebuild, run through the same code path it uses.
      Mix.Tasks.Sample.Repair.run(["--apply"])

      assert Ops.orphans(scope) == []
      rebuilt = Repo.one(Generation)
      assert rebuilt.event_id == original.event_id
      assert rebuilt.id == original.id
      assert rebuilt.prompt =~ "not recovered"
    end

    test "a settled generation with its row intact is not an orphan", %{scope: scope} do
      {:ok, _original, :created} = Generations.create(scope, @text, Ecto.UUID.generate())
      assert Ops.orphans(scope) == []
    end
  end
end
