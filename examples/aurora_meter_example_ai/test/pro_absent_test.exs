defmodule AuroraMeterExampleAi.ProAbsentTest do
  @moduledoc """
  I20: the Pro profile is an optional integration and the core profile is
  provably unaffected by its absence.

  Every test here runs in **both** profiles and asserts the right thing in
  each, rather than skipping in one. A test that is excluded when the flag is
  set is a test that has never seen the case it exists for.
  """
  use AuroraMeterExampleAiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AuroraMeterExampleAi.Pro

  @app_root Path.expand("..", __DIR__)

  # The one file outside the Pro trees that may name `AuroraMeter.Pro`, and the
  # two trees whose module bodies must be guarded.
  @boundary "lib/aurora_meter_example_ai/pro.ex"
  @guarded_trees ["lib/aurora_meter_example_ai/pro/", "lib/aurora_meter_example_ai_web/pro/"]

  # `AuroraMeterExampleAi.Pro` must not match: it is this application's own
  # module and it is compiled in both profiles. The word boundary after `Pro`
  # keeps `AuroraMeter.Product` (if one were ever added) out too.
  @mention ~r/\bAuroraMeter\.Pro\b/
  @guard "if Code.ensure_loaded?(AuroraMeter.Pro) do"

  describe "the build and the environment agree" do
    test "I20 available?/0 reports the profile the environment asked for" do
      asked = System.get_env("AURORA_SAMPLE_PRO") == "1"

      assert Pro.available?() == asked, """
      This build has Aurora Meter Pro in it: #{Pro.available?()}. \
      AURORA_SAMPLE_PRO asked for it: #{asked}.

      The flag selects the dependency tree AND the lockfile in mix.exs, so the two cannot \
      disagree unless the build is stale. Run `mix deps.get && mix compile` with the flag in \
      the state you want.
      """
    end

    test "I20 profile/0 agrees with available?/0" do
      assert Pro.profile() == if(pro?(), do: :pro, else: :core)
    end

    test "I20 AuroraMeter.Pro is defined exactly when the profile says it is" do
      # The assertion the whole guard rests on, made against the code server
      # rather than against the flag. `Code.ensure_loaded?/1` is used here
      # rather than `function_exported?/2` on an unloaded module, which can
      # never be true and therefore can never fail (open-findings X325's
      # family).
      assert Code.ensure_loaded?(AuroraMeter.Pro) == Pro.available?()
    end
  end

  describe "the compiled application" do
    # ---------------------------------------------------------------------
    # Why this asks the compiler rather than grepping the source
    # ---------------------------------------------------------------------
    #
    # The first version of this test grepped `lib/` for the string
    # `AuroraMeter.Pro` and failed on `lib/aurora_meter_example_ai/failures.ex`,
    # which names `AuroraMeter.Pro.Recovery` **inside a sentence** that a
    # recipe prints to a reader in the core profile. That sentence cannot
    # raise, cannot be called and is exactly what a good refusal message
    # contains: `AuroraMeterExampleAi.Pro.require!/1`'s own message names the
    # package and the Hex organisation.
    #
    # So the instrument was wrong rather than the code. What I20 is about is a
    # **call site**, and the compiler already knows every one of those: each
    # `.beam` file carries an import table listing every remote function the
    # module references. A string literal is not in it and a call is. This is
    # the same class of narrowing `no_payment_test.exs` and `profile_test.exs`
    # record, arrived at the same way: by watching the obvious instrument fire
    # on the honest half of the application.
    test "I20 no module in this application references AuroraMeter.Pro outside the guarded trees" do
      offenders =
        app_modules()
        |> Enum.map(fn module -> {module, pro_references(module)} end)
        |> Enum.reject(fn {_module, refs} -> refs == [] end)
        |> Enum.reject(fn {module, _refs} -> module in allowed_referrers() end)

      assert offenders == [], """
      These compiled modules reference AuroraMeter.Pro: \
      #{Enum.map_join(offenders, ", ", fn {m, refs} -> "#{inspect(m)} (#{inspect(refs)})" end)}.

      A call site outside a guarded module compiles in the core profile and raises \
      UndefinedFunctionError the first time a reader without a licence reaches it. Ask \
      AuroraMeterExampleAi.Pro.available?/0, or move the module into \
      lib/aurora_meter_example_ai/pro/.
      """
    end

    test "I20 in the core profile NOTHING in this application references AuroraMeter.Pro" do
      # The stronger statement, and it is only available in one profile. With
      # the guards compiled out there is no reference anywhere, including from
      # the boundary module: `Code.ensure_loaded?/1` takes the module name as
      # data, not as a call target.
      referencing =
        app_modules()
        |> Enum.filter(&(pro_references(&1) != []))

      if pro?() do
        assert referencing != [],
               "the Pro profile compiled no reference to AuroraMeter.Pro at all, so the guards removed everything"
      else
        assert referencing == [],
               "the core profile references: #{inspect(referencing)}"
      end
    end

    test "I20 the import-table reader can see a reference, so an empty result means clean" do
      # Without this, both tests above pass on a reader that always answers [].
      # `AuroraMeterExampleAi.Failures` is known to call `AuroraMeter.Credits`
      # in both profiles: if the reader cannot find that, it cannot find
      # anything.
      assert app_modules() != []
      assert length(app_modules()) > 20

      refs = remote_modules(AuroraMeterExampleAi.Failures)
      assert AuroraMeter.Credits in refs
      assert AuroraMeterExampleAi.Repo in refs

      # And it distinguishes the two module names, which is the thing a regex
      # over source has to be careful about and this does not.
      refute AuroraMeter.Pro in remote_modules(AuroraMeterExampleAi.Tokens)
    end

    test "I20 the boundary module names AuroraMeter.Pro in source but does not call it" do
      source = @app_root |> Path.join(@boundary) |> File.read!()

      assert source =~ @mention, "the boundary module is where the guard lives"

      assert Enum.all?(
               source
               |> String.split("\n")
               |> code_lines()
               |> Enum.filter(&(&1 =~ @mention)),
               &(&1 =~ "Code.ensure_loaded?(AuroraMeter.Pro)")
             )

      # And the compiled answer agrees with the source: `Code.ensure_loaded?/1`
      # takes the name as data, so in the core profile the boundary module's
      # import table has no AuroraMeter.Pro function in it at all.
      unless pro?() do
        assert pro_references(AuroraMeterExampleAi.Pro) == []
      end
    end

    test "I20 the boundary module's only code mention is inside Code.ensure_loaded?/1" do
      lines = @app_root |> Path.join(@boundary) |> File.read!() |> String.split("\n")

      # Documentation is allowed to name the module; code is not, except inside
      # the one call that answers `false` rather than raising when it is
      # absent. `code_lines/1` drops heredocs and comments, and the second
      # assertion below proves it actually dropped some, so "no offending code
      # line" cannot mean "no code lines at all".
      code = code_lines(lines)
      assert length(code) < length(Enum.filter(lines, &(&1 =~ @mention))) + length(code)

      mentions = Enum.filter(code, &(&1 =~ @mention))

      assert mentions != [],
             "the boundary module has no code mention at all, so it guards nothing"

      unguarded = Enum.reject(mentions, &(&1 =~ "Code.ensure_loaded?(AuroraMeter.Pro)"))

      assert unguarded == [],
             "#{@boundary} names AuroraMeter.Pro in code outside Code.ensure_loaded?/1: #{inspect(unguarded)}"
    end

    test "I20 code_lines/1 drops documentation and keeps code" do
      # The previous test is only as good as this helper, so the helper has its
      # own control: a heredoc containing the mention must not survive, and a
      # line of code containing it must.
      sample = [
        ~s(  @moduledoc """),
        "  prose naming AuroraMeter.Pro in documentation",
        ~s(  """),
        "  # a comment naming AuroraMeter.Pro",
        "  @available Code.ensure_loaded?(AuroraMeter.Pro)"
      ]

      kept = code_lines(sample)

      assert kept == ["  @available Code.ensure_loaded?(AuroraMeter.Pro)"]
    end

    test "I20 every module in a guarded tree is wrapped in the compile-time guard" do
      guarded =
        @guarded_trees
        |> Enum.flat_map(fn tree ->
          tree_path = Path.join(@app_root, tree)
          if File.dir?(tree_path), do: elixir_files(tree_path), else: []
        end)

      # The Pro profile has to have built something, or this test is vacuous in
      # the profile it matters most in.
      if pro?() do
        assert guarded != [],
               "the Pro profile compiled no guarded module at all, so there is nothing to guard"
      end

      unguarded =
        guarded
        |> Enum.reject(&(File.read!(&1) =~ @guard))
        |> Enum.map(&Path.relative_to(&1, @app_root))

      assert unguarded == [], """
      These files live in a guarded tree and do not open with #{inspect(@guard)}: \
      #{Enum.join(unguarded, ", ")}.
      """
    end
  end

  describe "the core profile's surfaces" do
    test "I20 no core-profile route mentions billing, checkout or a webhook" do
      routes = AuroraMeterExampleAiWeb.Router.__routes__() |> Enum.map(& &1.path)

      money_routes =
        Enum.filter(routes, fn path ->
          path =~ ~r/billing|checkout|webhook|top-?up|stripe/i
        end)

      if pro?() do
        assert money_routes != [],
               "the Pro profile must add the billing routes, or the guard removed too much"

        assert "/billing" in routes

        # The webhook is deliberately NOT a router route: it has to be above
        # `Plug.Parsers` or Stripe's signature can never verify. So the
        # assertion is behavioural rather than a table lookup: an unsigned POST
        # must reach the plug and be refused, not 404.
        assert %{status: 400} =
                 build_conn()
                 |> Plug.Conn.put_req_header("content-type", "application/json")
                 |> post("/webhooks/stripe", ~s({"id":"evt_none"}))
      else
        assert money_routes == [], """
        The core profile's route table contains #{inspect(money_routes)}. A reader without a \
        licence must not have a route that leads to a payment surface at all, working or not.
        """

        assert %{status: 404} =
                 build_conn()
                 |> Plug.Conn.put_req_header("content-type", "application/json")
                 |> post("/webhooks/stripe", "{}")
      end
    end

    test "I20 the /generate page shows a top-up affordance exactly when Pro is present",
         %{conn: _} = context do
      %{conn: conn} = log_in_org_owner(context)

      {:ok, view, html} = live(conn, ~p"/generate")
      assert render(view) =~ "Generate"

      if pro?() do
        assert html =~ "Top up"
      else
        refute html =~ "Top up"
        refute html =~ "top up"
        refute html =~ "Add credit"

        # The stronger half: not present and disabled, not present and
        # explaining itself. Absent.
        refute html =~ "billing"
        refute html =~ "/billing"
      end
    end
  end

  # Every module this application compiled, from the application spec rather
  # than from a wildcard over the filesystem.
  defp app_modules do
    Application.spec(:aurora_meter_example_ai, :modules) || []
  end

  # Every remote module this module's compiled code references, read out of the
  # BEAM's own import table. A string literal naming a module is not in it.
  defp remote_modules(module) do
    case :code.which(module) do
      path when is_list(path) ->
        case :beam_lib.chunks(path, [:imports]) do
          {:ok, {^module, [imports: imports]}} ->
            imports |> Enum.map(fn {m, _f, _a} -> m end) |> Enum.uniq()

          _other ->
            []
        end

      _not_a_file ->
        []
    end
  end

  defp pro_references(module) do
    module
    |> remote_modules()
    |> Enum.filter(fn referenced ->
      name = Atom.to_string(referenced)
      name == "Elixir.AuroraMeter.Pro" or String.starts_with?(name, "Elixir.AuroraMeter.Pro.")
    end)
  end

  # The modules that are allowed to reference Pro: the boundary and everything
  # in the two guarded trees, resolved from the files that are actually there
  # so a new guarded module needs no edit here and a module moved OUT of a
  # guarded tree loses its exemption immediately.
  defp allowed_referrers do
    guarded_files =
      @guarded_trees
      |> Enum.flat_map(fn tree ->
        tree_path = Path.join(@app_root, tree)
        if File.dir?(tree_path), do: elixir_files(tree_path), else: []
      end)

    modules_from = fn path ->
      Enum.filter(app_modules(), fn module ->
        case :code.which(module) do
          beam when is_list(beam) ->
            source = module.module_info(:compile)[:source]
            is_list(source) and Path.expand(List.to_string(source)) == Path.expand(path)

          _ ->
            false
        end
      end)
    end

    boundary_modules = modules_from.(Path.join(@app_root, @boundary))

    Enum.uniq(boundary_modules ++ Enum.flat_map(guarded_files, modules_from))
  end

  defp elixir_files(dir) do
    dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  # Lines of code: heredocs and `#` comments removed. Deliberately simple, and
  # its own test above is what makes it trustworthy rather than its cleverness.
  defp code_lines(lines) do
    {kept, _in_doc} =
      Enum.reduce(lines, {[], false}, fn line, {kept, in_doc} ->
        cond do
          String.contains?(line, ~s(""")) -> {kept, not in_doc}
          in_doc -> {kept, in_doc}
          String.starts_with?(String.trim(line), "#") -> {kept, in_doc}
          String.trim(line) == "" -> {kept, in_doc}
          true -> {[line | kept], in_doc}
        end
      end)

    Enum.reverse(kept)
  end

  # Asked at runtime rather than through the compile-time constant, so the
  # compiler cannot fold one branch of an `if` away and warn that the other is
  # unreachable. The two are tied together by the first test in this file.
  defp pro?, do: Code.ensure_loaded?(AuroraMeter.Pro)
end
