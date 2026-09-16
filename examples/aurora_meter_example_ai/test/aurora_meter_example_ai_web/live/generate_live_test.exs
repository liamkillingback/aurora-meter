defmodule AuroraMeterExampleAiWeb.GenerateLiveTest do
  @moduledoc """
  The G09 browser bullet: authentication, organisation isolation, double-click
  actions, quota denial, holds and settlement, and live updates.
  """
  use AuroraMeterExampleAiWeb.ConnCase, async: false
  use AuroraMeter.Test, reset: true

  import Phoenix.LiveViewTest

  alias AuroraMeter.Credits
  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAi.Generations.Generation
  alias AuroraMeterExampleAi.Repo
  alias AuroraMeterExampleAi.SampleFixtures

  @submit %{
    "generation" => %{
      "kind" => "text",
      "prompt" => "a poem about a ledger",
      "model" => "nimbus-1-mini"
    }
  }

  defp submit(params \\ %{}, request_id) do
    %{"generation" => Map.merge(@submit["generation"], Map.put(params, "request_id", request_id))}
  end

  describe "authentication" do
    test "an unauthenticated visitor to /generate is sent to the log in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/generate")
    end

    test "an unauthenticated visitor to /ops is sent to the log in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/ops")
    end

    test "a signed-in member is refused the operational pages", %{conn: _conn} = context do
      %{conn: conn} = log_in_org_member(context)
      assert {:error, {:redirect, %{to: "/generate"}}} = live(conn, ~p"/ops")
      assert {:error, {:redirect, %{to: "/generate"}}} = live(conn, ~p"/dev/tools")
    end

    test "a signed-in owner is not", %{conn: _conn} = context do
      %{conn: conn} = log_in_org_owner(context)
      assert {:ok, _view, _html} = live(conn, ~p"/ops")
    end
  end

  describe "the generation path" do
    setup :log_in_org_owner

    test "a submit settles, and the page shows the estimate and the actual", %{
      conn: conn,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/generate")
      before = Credits.summary(org)

      html = view |> form("#generate-form") |> render_submit(submit(Ecto.UUID.generate()))

      assert html =~ "Generated."
      generation = Repo.one(Generation)
      assert generation.status == "settled"
      assert generation.cost_micros < generation.estimate_micros

      assert Credits.summary(org).available == before.available - generation.cost_micros
      assert Credits.summary(org).held == 0
    end

    test "a double-click submit of one form produces one generation, one event and one hold",
         %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/generate")
      request_id = Ecto.UUID.generate()
      params = submit(request_id)

      first = view |> form("#generate-form") |> render_submit(params)
      second = view |> form("#generate-form") |> render_submit(params)

      assert first =~ "Generated."
      assert second =~ "had already been run"

      assert Repo.aggregate(Generation, :count) == 1
      assert Repo.aggregate(AuroraMeterExampleAi.SampleOutbox.Item, :count) == 1

      reference = Generations.reference(request_id)

      assert org
             |> Credits.history(kinds: [:hold], limit: 20)
             |> Enum.count(&(&1.reference == reference)) == 1
    end

    test "a generation whose work raises leaves usage and balance unchanged",
         %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/generate")
      before = Credits.summary(org)
      images_before = AuroraMeter.usage(org, :images)

      html =
        view
        |> form("#generate-form")
        |> render_submit(
          submit(%{"kind" => "image", "prompt" => "fail: on purpose"}, Ecto.UUID.generate())
        )

      assert html =~ "Nothing was charged"
      assert Credits.summary(org).available == before.available
      assert Credits.summary(org).held == 0
      assert AuroraMeter.usage(org, :images) == images_before
    end
  end

  describe "quota denial" do
    test "a free organisation's sixth image is denied, and the denial names the limit and the period end",
         %{conn: conn} do
      org = SampleFixtures.org_fixture(%{plan: :free})
      scope = SampleFixtures.scope_fixture(org)
      {:ok, _} = Credits.grant(org, 50_000_000, reference: SampleFixtures.grant_reference())
      conn = log_in_user(conn, scope.user)

      {:ok, view, _html} = live(conn, ~p"/generate")
      image = %{"kind" => "image", "prompt" => "a picture of a ledger"}

      for _ <- 1..5 do
        view |> form("#generate-form") |> render_submit(submit(image, Ecto.UUID.generate()))
      end

      assert AuroraMeter.usage(org, :images) == 5

      html = view |> form("#generate-form") |> render_submit(submit(image, Ecto.UUID.generate()))

      assert html =~ "allows 5 images this period"
      assert html =~ "The period ends"
      assert AuroraMeter.usage(org, :images) == 5
    end

    test "an organisation with no credit is refused before any work runs", %{conn: conn} do
      org = SampleFixtures.org_fixture()
      scope = SampleFixtures.scope_fixture(org)
      conn = log_in_user(conn, scope.user)

      {:ok, view, _html} = live(conn, ~p"/generate")
      html = view |> form("#generate-form") |> render_submit(submit(Ecto.UUID.generate()))

      assert html =~ "Not enough credit"
      assert Repo.aggregate(Generation, :count) == 0
    end
  end

  describe "the low balance banner" do
    test "it appears when available crosses the threshold and not before", %{conn: conn} do
      threshold = AuroraMeter.Config.credits_low_balance_threshold()
      assert is_integer(threshold) and threshold > 0

      org = SampleFixtures.org_fixture()
      scope = SampleFixtures.scope_fixture(org)
      {:ok, _} = Credits.grant(org, threshold * 2, reference: SampleFixtures.grant_reference())
      conn = log_in_user(conn, scope.user)

      {:ok, view, html} = live(conn, ~p"/generate")
      refute html =~ "low-balance-banner"

      # Spend down past the threshold without going through a generation, so
      # the test is about the banner rather than about the generation path.
      {:ok, _} = Credits.debit(org, threshold + 1, SampleFixtures.grant_reference("spend"), %{})

      html = view |> form("#generate-form") |> render_submit(submit(Ecto.UUID.generate()))
      assert html =~ "low-balance-banner"
      assert html =~ "Low balance"
    end
  end

  describe "live updates" do
    test "a generation in one session moves the meter and the balance in a second session for the same organisation",
         %{conn: conn} do
      scope = SampleFixtures.funded_scope_fixture()
      conn = log_in_user(conn, scope.user)

      {:ok, watcher, _html} = live(conn, ~p"/generate")
      {:ok, actor, _html} = live(build_conn() |> log_in_user(scope.user), ~p"/generate")

      before = render(watcher)

      actor
      |> form("#generate-form")
      |> render_submit(submit(%{"kind" => "image"}, Ecto.UUID.generate()))

      # The broadcast is what moves the watcher. It is driven rather than waited
      # for, because a test that sleeps until a timer fires is a test that fails
      # on a slow machine.
      AuroraMeter.Test.broadcast!()

      after_ = render(watcher)

      refute after_ == before,
             "the second session did not change at all, so this test cannot see a live update"

      assert after_ =~ "1 / 200",
             "the watcher's image meter did not move: it still reads the old value"
    end

    test "a generation in one organisation changes nothing in another organisation's session", %{
      conn: conn
    } do
      watcher_scope = SampleFixtures.funded_scope_fixture()
      actor_scope = SampleFixtures.funded_scope_fixture()

      {:ok, watcher, _html} = live(log_in_user(conn, watcher_scope.user), ~p"/generate")
      {:ok, actor, _html} = live(log_in_user(build_conn(), actor_scope.user), ~p"/generate")

      before = render(watcher)

      actor
      |> form("#generate-form")
      |> render_submit(submit(%{"kind" => "image"}, Ecto.UUID.generate()))

      AuroraMeter.Test.broadcast!()

      assert render(watcher) == before

      # And the positive half, so "nothing changed" is not just "nothing ever
      # changes here".
      watcher
      |> form("#generate-form")
      |> render_submit(submit(%{"kind" => "image"}, Ecto.UUID.generate()))

      AuroraMeter.Test.broadcast!()
      refute render(watcher) == before
    end
  end
end
