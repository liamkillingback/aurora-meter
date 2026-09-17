defmodule AuroraMeterExampleAi.ProfileTest do
  @moduledoc """
  What the core profile must not contain.

  The core profile is MIT, runs with Elixir and Postgres and nothing else, and
  names no commercial module and no provider. `09d` adds a Pro profile on top of
  this tree; until it does, and after it does, nothing outside its own guarded
  modules may mention `AuroraMeter.Pro`.
  """
  use ExUnit.Case, async: true

  @all_sources Path.wildcard("lib/**/*.{ex,exs}") ++ Path.wildcard("config/*.exs")

  # The Pro profile's own files. `09d` added them and this test's own module
  # documentation predicted them: "nothing outside its own guarded modules may
  # mention AuroraMeter.Pro". These are those modules, named one by one rather
  # than by a pattern loose enough to hide a fourth.
  @pro_sources [
    "lib/aurora_meter_example_ai/pro.ex",
    "config/pro.exs",
    "config/pro_test.exs"
  ]
  @pro_trees ["lib/aurora_meter_example_ai/pro/", "lib/aurora_meter_example_ai_web/pro/"]

  @sources Enum.reject(@all_sources, fn path ->
             path in @pro_sources or Enum.any?(@pro_trees, &String.starts_with?(path, &1))
           end)

  test "the Pro profile's files are a real subset, not a typo that excluded nothing" do
    # Every path in the exclusion list must actually exist, or the exclusion is
    # silently doing nothing and the greps below are running over a tree that
    # only looks clean. A stale entry here is exactly how a scan stops working.
    for path <- @pro_sources do
      assert File.exists?(path),
             "#{path} is excluded from the core-profile greps but is not there"
    end

    for tree <- @pro_trees do
      assert File.dir?(tree), "#{tree} is excluded from the core-profile greps but is not there"
      assert Path.wildcard(tree <> "**/*.ex") != [], "#{tree} is empty"
    end

    assert length(@sources) < length(@all_sources)
  end

  test "the file list is not empty" do
    # The instrument's own floor. A wildcard that matched nothing would make
    # every test below pass on an empty list, which is X325's family.
    assert length(@sources) > 20, "only #{length(@sources)} source files were found"
  end

  test "no code in the core profile calls a Pro module" do
    # Narrowed by 09d from "names" to "calls", for the reason set out under
    # "The provider rule" below and for one more that is specific to this
    # pattern: `docs/failures.md`'s exporter_timeout recipe has to **print**
    # `AuroraMeter.Pro.Recovery.acknowledge_item/2` to a reader in the core
    # profile, because naming the commercial mechanism is the honest answer to
    # "what would I do about this item". A rule that forbids the sentence makes
    # the recipe worse and protects nothing: the compiled-import test below is
    # what actually proves the core profile calls nothing.
    offenders = Enum.reject(grep_code(~r/AuroraMeter\.Pro\b/), &in_string?/1)

    assert offenders == [],
           "the core profile calls a commercial module:\n" <> Enum.join(offenders, "\n")
  end

  # ---------------------------------------------------------------------------
  # The provider rule, as 09d had to narrow it, and why
  # ---------------------------------------------------------------------------
  #
  # 09c's version of this test grepped every line of every file for the word
  # "Stripe". It passed while the sample had no Pro profile at all, and it fails
  # the moment the sample has to EXPLAIN that it has one: the endpoint's comment
  # saying why the webhook is mounted above `Plug.Parsers`, the redaction
  # filter's table of key prefixes, the router's note saying the webhook is
  # deliberately not a route. Every one of those is the sample being honest
  # about a boundary, and a rule that forbids them is a rule that makes the
  # sample worse.
  #
  # This is the same amendment `no_payment_test.exs` records for pages, for the
  # same reason: **you cannot say there is no payment here without the word.**
  # What the criterion is actually about is CALLS, not vocabulary. So:
  #
  #   * code lines only, comments and documentation excluded, and `code_lines/1`
  #     has its own control below because the rule is only as good as it is;
  #   * a module call (`Stripe.`, `AuroraMeter.Pro.`) or a dependency name, not
  #     a word in a sentence or a link label;
  #   * key shapes over the WHOLE file, comments included, because a key in a
  #     comment is still a key. That half does not soften and has its own test.
  #
  # The rendered-page half of the same question is `no_payment_test.exs` rule 4,
  # which asserts no provider is named on any core-profile page at all. Between
  # the two, "the core profile has no provider in it" is asserted where it can
  # be measured rather than where it is easiest to grep.
  test "no code in the core profile calls a payment provider or a commercial module" do
    offenders =
      Enum.reject(
        grep_code(~r/\bStripe\.|\bstripity_stripe\b|\bAuroraMeter\.Pro\./),
        &in_string?/1
      )

    assert offenders == [],
           "the core profile calls a payment provider:\n" <> Enum.join(offenders, "\n")
  end

  test "the compiled core profile references no Pro module and no Stripe module at all" do
    # The source scan above narrows twice (code lines, and not inside a string)
    # and each narrowing is a judgement. This one is not: it reads every
    # compiled module's own import table, which is the compiler's answer to
    # "what does this module call". A sentence in a message is not in it.
    referencing =
      for module <- Application.spec(:aurora_meter_example_ai, :modules) || [],
          referenced <- remote_modules(module),
          name = Atom.to_string(referenced),
          String.starts_with?(name, "Elixir.Stripe.") or name == "Elixir.Stripe" or
            String.starts_with?(name, "Elixir.AuroraMeter.Pro"),
          do: {module, referenced}

    if System.get_env("AURORA_SAMPLE_PRO") == "1" do
      assert referencing != [], "the Pro profile compiled no reference to Pro or Stripe at all"
    else
      assert referencing == [], "the core profile references: #{inspect(referencing)}"
    end
  end

  test "control: the import-table reader can see a reference" do
    refs = remote_modules(AuroraMeterExampleAi.Generations)
    assert AuroraMeter.Credits in refs
    assert AuroraMeterExampleAi.Repo in refs
  end

  test "no file in the core profile contains a credential shape, comments included" do
    offenders =
      Enum.filter(@all_sources, fn path ->
        AuroraMeterExampleAi.Redact.credential_shaped?(File.read!(path))
      end)

    assert offenders == [],
           "a credential-shaped string is in the source:\n" <> Enum.join(offenders, "\n")
  end

  test "control: the code grep sees a call and ignores the same word in prose" do
    # Three negatives above rest on `grep_code/1`. This is the leg that shows it
    # can fire, and that it distinguishes the two cases the amendment turns on.
    assert code_lines(["    Stripe.Customer.retrieve(id)"]) != []
    assert code_lines(["    # Stripe signs the raw body"]) == []
    assert code_lines([~s(    @moduledoc """), "    names Stripe in prose", ~s(    """)]) == []

    assert Regex.match?(~r/\bStripe\./, "Stripe.Customer.retrieve(id)")
    refute Regex.match?(~r/\bStripe\./, ~s(<.link navigate="/billing">Top up at Stripe</.link>))
  end

  test "no source makes a network call" do
    offenders =
      grep(
        ~r/\b(HTTPoison|Finch\.request|Req\.(get|post|put|delete)|:httpc|:gen_tcp|:ssl\.connect)\b/
      )

    assert offenders == [],
           "the core profile contacts the network:\n" <> Enum.join(offenders, "\n")
  end

  test "the greps can find something" do
    # Control. Three assertions above are negatives over the same function; if
    # `grep/1` could not match, all three would pass on any tree at all. This
    # asks it for a pattern that must be present.
    assert grep(~r/AuroraMeter\.with_quota/) != []
    assert grep(~r/AuroraMeter\.record/) != []
    assert grep(~r/Credits\.with_credits/) != []
  end

  test "the sample declares the aurora_meter path dependency, and the commercial one only under the flag" do
    mix_exs = File.read!("mix.exs")
    assert mix_exs =~ ~s|{:aurora_meter, path: "../.."}|

    # 09d made `mix.exs` the one file that has to name the commercial package,
    # because that is where the opt-in lives. What matters is that naming it
    # there adds nothing to a build that did not ask: the dependency is inside
    # `pro_deps/0`, `pro_deps/0` is empty unless `AURORA_SAMPLE_PRO=1`, and the
    # assertion below is about the resolved tree rather than about the text.
    assert mix_exs =~ "aurora_meter_pro"
    assert mix_exs =~ ~s|System.get_env("AURORA_SAMPLE_PRO") == "1"|

    declared = Mix.Project.config()[:deps] |> Enum.map(&elem(&1, 0))
    asked = System.get_env("AURORA_SAMPLE_PRO") == "1"

    assert :aurora_meter_pro in declared == asked, """
    The declared dependency list contains :aurora_meter_pro: #{:aurora_meter_pro in declared}. \
    AURORA_SAMPLE_PRO asked for it: #{asked}. The flag is the whole of the opt in and the \
    dependency list has to follow it.
    """

    # And the same fact from the other side: the module either exists in this
    # build or it does not, which is what every guard in the application asks.
    assert Code.ensure_loaded?(AuroraMeter.Pro) == asked

    # The declared list is read from the real project rather than from a
    # parsed string, and it has to be non-trivial or the assertion above is
    # about an empty list.
    assert :aurora_meter in declared
    assert length(declared) > 10

    # And the two lockfiles are both committed, so both resolutions are
    # reproducible rather than whatever Hex last resolved.
    assert File.exists?("mix.lock")
    assert File.exists?("mix.pro.lock")

    core_lock = File.read!("mix.lock")
    pro_lock = File.read!("mix.pro.lock")

    # What the Pro profile adds, asserted through the two dependencies it
    # brings with it rather than through `aurora_meter_pro` itself.
    #
    # `aurora_meter_pro` does NOT appear in either lockfile here, and that is
    # not an omission: a **path** dependency is never locked, because there is
    # no version, no checksum and no repository to pin. In this repository the
    # sibling checkout at ../../../aurora_meter_pro is present, so `pro_dep/0`
    # takes the path branch, exactly as Aurora Meter Pro's own `core_dep/0`
    # does for core. A customer's copy has no sibling, takes the Hex branch,
    # and locks `aurora_meter_pro` with a version and a checksum like any other
    # package. Asserting the Hex shape from here would be asserting something
    # this tree cannot produce.
    for package <- ~w(oban stripity_stripe) do
      assert pro_lock =~ ~s|"#{package}"|, "mix.pro.lock does not lock #{package}"
      refute core_lock =~ ~s|"#{package}"|, "mix.lock locks #{package}, which is Pro's"
    end
  end

  defp grep(regex) do
    Enum.flat_map(@sources, fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)
      |> Enum.map(fn {line, n} -> "#{path}:#{n}: #{String.trim(line)}" end)
    end)
  end

  # True when the whole matching part of the line sits inside a double-quoted
  # string, which is what a module name printed in a message looks like. Cheap
  # and deliberately conservative: it only exempts a line whose match is
  # between quotes on that same line.
  defp in_string?(entry) do
    line = entry |> String.split(": ", parts: 2) |> List.last()

    case Regex.run(~r/"([^"]*)"/, line) do
      [_, inside] ->
        Regex.match?(~r/\bStripe\.|\bstripity_stripe\b|\bAuroraMeter\.Pro\b/, inside)

      nil ->
        false
    end
  end

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

  # Like `grep/1`, over code lines only.
  defp grep_code(regex) do
    Enum.flat_map(@sources, fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> code_lines()
      |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)
      |> Enum.map(fn {line, n} -> "#{path}:#{n}: #{String.trim(line)}" end)
    end)
  end

  # Lines of code: heredocs, `#` comments and HEEx comments removed.
  # Deliberately simple, and the control test above is what makes it
  # trustworthy rather than its cleverness. Accepts bare lines or
  # `{line, number}` pairs so the control can call it with either.
  defp code_lines(lines) do
    {kept, _state} =
      Enum.reduce(lines, {[], %{doc: false, heex: false}}, fn entry, {kept, state} ->
        line = if is_tuple(entry), do: elem(entry, 0), else: entry
        trimmed = String.trim(line)

        cond do
          # A HEEx comment can run over several lines, so it has its own state
          # rather than being dropped a line at a time.
          state.heex ->
            {kept, %{state | heex: not String.contains?(line, "--%>")}}

          String.starts_with?(trimmed, "<%!--") ->
            {kept, %{state | heex: not String.contains?(line, "--%>")}}

          String.contains?(line, ~s(""")) ->
            {kept, %{state | doc: not state.doc}}

          state.doc ->
            {kept, state}

          String.starts_with?(trimmed, "#") ->
            {kept, state}

          trimmed == "" ->
            {kept, state}

          true ->
            {[entry | kept], state}
        end
      end)

    Enum.reverse(kept)
  end
end
