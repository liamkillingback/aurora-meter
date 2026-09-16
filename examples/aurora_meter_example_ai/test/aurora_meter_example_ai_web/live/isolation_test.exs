defmodule AuroraMeterExampleAiWeb.IsolationTest do
  @moduledoc """
  Organisation isolation, proved three ways, because one way is not enough.

  Phase 08 of this programme shipped an IDOR because an operational dashboard
  read `params["tenant"]` before it read the session. The gate bullet it failed
  is owed here (finding X352), and the shape the finding asks for is the one 08b
  used to close its half: make the forbidden tenant **unresolvable**, so that
  "the other organisation was never read" is a property of the run rather than
  of a rendered string that could coincide.

  So:

    1. **Structural.** No module under `lib/` reads an organisation or a tenant
       out of request parameters. A source scan, with a control that proves the
       scan can fail.
    2. **Behavioural.** Another organisation's generation is not reachable by
       id, and the refusal is indistinguishable from "no such row".
    3. **Over the run.** Every tenant key the application resolved while
       serving one organisation's session is that organisation's key, and the
       other's never appears. That is the half a rendered page cannot give you.
  """
  use AuroraMeterExampleAiWeb.ConnCase, async: false
  use AuroraMeter.Test, reset: true

  import Phoenix.LiveViewTest

  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAi.SampleFixtures
  alias AuroraMeterExampleAi.Tenancy

  @text %{"kind" => "text", "prompt" => "a poem about a ledger", "model" => "nimbus-1-mini"}

  setup do
    mine = SampleFixtures.funded_scope_fixture()
    theirs = SampleFixtures.funded_scope_fixture()

    {:ok, theirs_generation, :created} =
      Generations.create(
        theirs,
        Map.put(@text, "prompt", "their private prompt"),
        Ecto.UUID.generate()
      )

    %{mine: mine, theirs: theirs, theirs_generation: theirs_generation}
  end

  describe "1. structural" do
    test "the scan sees every source file" do
      # A wildcard that matched nothing would make the test below pass on any
      # tree at all, including one with the defect in every file.
      assert length(sources()) > 15, "only #{length(sources())} files were scanned"
    end

    test "no module in lib/ reads an organisation or a tenant out of request parameters" do
      offenders =
        Enum.flat_map(sources(), fn path -> path |> File.read!() |> forbidden_reads(path) end)

      assert offenders == [],
             "an organisation is being read from request parameters:\n" <>
               Enum.join(offenders, "\n")
    end

    test "the scan can fail" do
      # The control X325's family exists for: an instrument whose pattern cannot
      # match anything reports clean on every tree, including a broken one.
      planted = """
      defmodule Bad do
        def mount(params, _session, socket) do
          org = Orgs.get_org!(params["org_id"])
          {:ok, assign(socket, :org, org)}
        end
      end
      """

      assert forbidden_reads(planted, "planted.ex") != [],
             "the scan cannot match the defect it exists to find"
    end

    test "the scan does not fire on prose about the defect" do
      # This is the reason the scan walks the AST rather than the lines. The
      # first version of it read the file line by line and reported
      # `tenancy.ex`, whose module documentation contains the sentence
      # "a dashboard that reads params[\\"tenant\\"]". A line scan cannot tell a
      # warning about a defect from the defect.
      prose = ~S'''
      defmodule Fine do
        @moduledoc """
        Never read the tenant from params["tenant"]: it is an IDOR.
        """
        # and not from params["org_id"] either
        def org(scope), do: scope.org
      end
      '''

      assert forbidden_reads(prose, "prose.ex") == [],
             "the scan fires on documentation, so it would be weakened until it saw nothing"
    end
  end

  describe "2. behavioural" do
    test "another organisation's generation is not reachable by id", context do
      conn = log_in_user(context.conn, context.mine.user)
      id = context.theirs_generation.id

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/history/#{id}") end
    end

    test "the same id IS reachable from its own organisation's session", context do
      # Discrimination. Without this, the test above would pass against a route
      # that is broken for everyone.
      conn = log_in_user(build_conn(), context.theirs.user)
      id = context.theirs_generation.id

      {:ok, _view, html} = live(conn, ~p"/history/#{id}")
      assert html =~ "their private prompt"
    end

    test "the domain funnel refuses it too, not just the page", context do
      assert Generations.get(context.mine, context.theirs_generation.id) == nil
      assert Generations.get(context.theirs, context.theirs_generation.id) != nil

      assert_raise Ecto.NoResultsError, fn ->
        Generations.get!(context.mine, context.theirs_generation.id)
      end
    end

    test "the history list never carries another organisation's prompt", context do
      conn = log_in_user(context.conn, context.mine.user)
      {:ok, _view, html} = live(conn, ~p"/history")
      refute html =~ "their private prompt"
    end
  end

  describe "3. over the run" do
    test "serving one organisation resolves that organisation's key and no other", context do
      conn = log_in_user(context.conn, context.mine.user)
      mine_key = Tenancy.to_key(context.mine.org)
      theirs_key = Tenancy.to_key(context.theirs.org)
      assert mine_key != theirs_key

      {_result, keys} =
        SampleFixtures.with_tenant_probe(fn ->
          {:ok, view, _html} = live(conn, ~p"/generate")

          view
          |> form("#generate-form")
          |> render_submit(%{
            "generation" => Map.put(@text, "request_id", Ecto.UUID.generate())
          })

          {:ok, _ops, _html} = live(conn, ~p"/ops")
          {:ok, _history, _html} = live(conn, ~p"/history")
        end)

      assert keys != [], "the probe recorded nothing, so it is measuring nothing"
      assert mine_key in keys, "the probe never saw the organisation that WAS being served"

      refute theirs_key in keys,
             "the other organisation's tenant key was resolved during this run: #{inspect(Enum.uniq(keys))}"

      assert Enum.uniq(keys) == [mine_key]
    end

    test "the probe can see a forbidden key when one really is resolved", context do
      # The control. If the probe could not see a cross-tenant resolution, the
      # test above would pass on a tree that leaks every organisation.
      theirs_key = Tenancy.to_key(context.theirs.org)

      {_result, keys} =
        SampleFixtures.with_tenant_probe(fn ->
          AuroraMeter.usage(context.theirs.org, :tokens)
        end)

      assert theirs_key in keys, "the probe cannot see a resolution it was built to see"
    end
  end

  describe "the operational pages show one organisation" do
    test "the ops page shows this organisation's tenant key and no other", context do
      conn = log_in_user(context.conn, context.mine.user)
      {:ok, _view, html} = live(conn, ~p"/ops")

      assert html =~ Tenancy.to_key(context.mine.org)
      refute html =~ Tenancy.to_key(context.theirs.org)
    end

    test "there is no organisation switcher and no organisation parameter on any route" do
      # `/ops?tenant=org_9` must be the same page as `/ops`. A page that accepts
      # the parameter and ignores it today accepts it next year too.
      routes = AuroraMeterExampleAiWeb.Router.__routes__()

      offenders =
        Enum.filter(routes, fn route ->
          String.contains?(route.path, ":org") or String.contains?(route.path, ":tenant")
        end)

      assert offenders == [],
             "a route carries an organisation in its path: #{inspect(Enum.map(offenders, & &1.path))}"
    end

    test "a tenant parameter in the query string changes nothing", context do
      conn = log_in_user(context.conn, context.mine.user)
      theirs_key = Tenancy.to_key(context.theirs.org)

      {:ok, _view, plain} = live(conn, ~p"/ops")

      {:ok, _view, spiked} =
        live(conn, "/ops?tenant=#{theirs_key}&org_id=#{context.theirs.org.id}")

      refute spiked =~ theirs_key
      assert visible_text(spiked) == visible_text(plain)
    end
  end

  defp sources, do: Path.wildcard("lib/**/*.ex")

  @forbidden_keys ~w(org org_id tenant tenant_key organisation organization)

  # Walks the parsed source rather than its lines. A comment and a documentation
  # string carry no AST nodes at all, so prose warning against the defect cannot
  # be mistaken for the defect, and `params["org_id"]` inside a heredoc is
  # invisible here exactly as it should be.
  defp forbidden_reads(source, path) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [Access, :get]}, meta, [_subject, key]} = node, acc
        when key in @forbidden_keys ->
          {node, ["#{path}:#{meta[:line]}: a request parameter #{inspect(key)} is read" | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # The isolation claim is about what a page SAYS, not about the session token
  # and the CSRF token, which differ between any two renders of any page.
  defp visible_text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\d+s\b/, "Ns")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
