defmodule AuroraMeterExampleAiWeb.Api.GenerationControllerTest do
  @moduledoc """
  `AuroraMeter.Plug.EnsureEntitled` in a pipeline, and `with_quota/4` in the
  action, and the difference between them.
  """
  use AuroraMeterExampleAiWeb.ConnCase, async: false
  use AuroraMeter.Test, reset: true

  alias AuroraMeter.Credits
  alias AuroraMeterExampleAi.Generations.Generation
  alias AuroraMeterExampleAi.Repo
  alias AuroraMeterExampleAi.SampleFixtures

  defp api(conn, org) do
    conn
    |> put_req_header("authorization", "Bearer " <> org.api_key)
    |> put_req_header("content-type", "application/json")
  end

  defp body(overrides \\ %{}) do
    Map.merge(
      %{"kind" => "image", "prompt" => "a picture of a ledger", "model" => "nimbus-1-mini"},
      overrides
    )
  end

  describe "authentication is the host's" do
    test "no bearer token is 401 and nothing is metered", %{conn: conn} do
      conn = post(conn, ~p"/api/generate", body())
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert Repo.aggregate(Generation, :count) == 0
    end

    test "a wrong bearer token is 401", %{conn: conn} do
      _org = SampleFixtures.org_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer sample_nope")
        |> post(~p"/api/generate", body())

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "a valid token gets through", %{conn: conn} do
      scope = SampleFixtures.funded_scope_fixture()
      conn = conn |> api(scope.org) |> post(~p"/api/generate", body())
      assert %{"outcome" => "created", "status" => "settled"} = json_response(conn, 201)
    end
  end

  describe "the plug is advisory" do
    test "a passing request carries the quota the plug read", %{conn: conn} do
      scope = SampleFixtures.funded_scope_fixture()
      conn = conn |> api(scope.org) |> post(~p"/api/generate", body())

      assert %{"quota_at_admission" => %{"kind" => "hard", "used" => 0, "limit" => 200}} =
               json_response(conn, 201)
    end

    test "the entitlement the plug consults distinguishes a declared feature from an undeclared one" do
      # Not a test of the plug. Both of this sample's plans declare `:images`,
      # so the plug's `:not_entitled` branch is unreachable through this route
      # without inventing a third plan, and inventing one to reach a branch is
      # how a sample grows a plan nobody uses.
      #
      # What this does assert is the decision underneath the plug: `entitled?`
      # separates a feature the plan has from one it does not. The plug's own
      # `:not_entitled` path is covered by the library's own suite (09a's
      # `09a-plug-matrix.md`), which is where it belongs.
      org = SampleFixtures.org_fixture(%{plan: :free})
      assert AuroraMeter.entitled?(org, :images)
      refute AuroraMeter.entitled?(org, :priority_queue)
    end

    test "the plug says yes and with_quota says no at the boundary", %{conn: conn} do
      # The window the documentation is about. The plug consults usage and sees
      # the hard limit, so at the cap it refuses with 402 through the host's own
      # error renderer. One below the cap it admits, and the action's
      # `with_quota/4` is what actually takes the slot.
      org = SampleFixtures.org_fixture(%{plan: :free})
      _scope = SampleFixtures.scope_fixture(org)
      {:ok, _} = Credits.grant(org, 50_000_000, reference: SampleFixtures.grant_reference())

      for _ <- 1..5 do
        assert conn |> api(org) |> post(~p"/api/generate", body()) |> json_response(201)
      end

      assert AuroraMeter.usage(org, :images) == 5

      refused = conn |> api(org) |> post(~p"/api/generate", body())
      assert %{"error" => "limit_exceeded", "advisory" => true} = json_response(refused, 402)
      assert AuroraMeter.usage(org, :images) == 5
    end
  end

  describe "identity over HTTP" do
    test "the same request_id twice is one generation and one charge", %{conn: conn} do
      scope = SampleFixtures.funded_scope_fixture()
      request_id = Ecto.UUID.generate()
      params = body(%{"request_id" => request_id})

      first = conn |> api(scope.org) |> post(~p"/api/generate", params)
      assert %{"outcome" => "created"} = json_response(first, 201)

      after_first = Credits.summary(scope.org)

      second = build_conn() |> api(scope.org) |> post(~p"/api/generate", params)
      assert %{"outcome" => "duplicate"} = json_response(second, 200)

      assert Repo.aggregate(Generation, :count) == 1
      assert Credits.summary(scope.org).available == after_first.available
    end
  end

  describe "refusals a client can act on" do
    test "no credit is 422 with a named reason", %{conn: conn} do
      # An organisation with an owner (the API acts as one) and no credit. An
      # organisation with no users at all authenticates as nobody and is 401,
      # which is a different answer to a different question.
      scope = SampleFixtures.funded_scope_fixture(%{credit: 0})
      conn = conn |> api(scope.org) |> post(~p"/api/generate", body())
      assert %{"error" => %{"kind" => "insufficient_credits"}} = json_response(conn, 422)
    end

    test "a failing workload is 422 and charges nothing", %{conn: conn} do
      scope = SampleFixtures.funded_scope_fixture()
      before = Credits.summary(scope.org)

      conn = conn |> api(scope.org) |> post(~p"/api/generate", body(%{"prompt" => "fail: here"}))
      assert %{"error" => %{"kind" => "provider_failed"}} = json_response(conn, 422)
      assert Credits.summary(scope.org).available == before.available
    end
  end
end
