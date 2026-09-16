defmodule AuroraMeter.NoOutboundIoTest do
  @moduledoc """
  D11 asserted rather than promised: no part of the free core opens a socket, a
  port or a shell of its own.

  "No telemetry that phones home" is a sentence in `AGENTS.md` and a claim on
  the storefront, and until this file it rested on nobody having added one. It
  is the kind of claim that is true until a well-meaning commit adds a crash
  reporter, and the commit that adds one should fail the build rather than ship.

  Core's allow list is **empty**. Not "small": a hit here is either a defect or
  a deliberate decision that needs an entry and a reason, and an empty list is
  the only version of this test that cannot rot quietly.

  It reads `lib/` as text after stripping heredocs and comments, because what is
  being looked for is a call site and the module names are the call sites. The
  known weakness is stated rather than hidden: `apply/3` with a computed module
  would not be seen. Nothing in `lib/` does that, and the check below asserts
  that too.
  """
  use ExUnit.Case, async: true

  @clients [
    ":httpc",
    ":gen_tcp",
    ":gen_udp",
    ":ssl.connect",
    ":socket.",
    ":inet.getaddr",
    "Finch.",
    "Req.",
    "HTTPoison.",
    "Mint.",
    "Tesla.",
    "Mojito.",
    "System.cmd",
    "Port.open",
    ":os.cmd",
    ":erlang.open_port"
  ]

  # Every dynamic `apply/3` target in `lib/`, as the source spells it, with what
  # bounds it. A target that is not here fails the test below rather than
  # quietly widening the scan's blind spot.
  @dynamic_targets %{
    "module" =>
      "the host's own callback module: a hold reconciler, an Oban operation's " <>
        "{module, function, arity}, or a storage case checkout. Host code either way.",
    "module(version)" =>
      "AuroraMeter.Migration.V<n>, built from an integer version by module/1 in the " <>
        "same file. Every possible value is a module of this package.",
    "Config" => "AuroraMeter.Config, with a retention window accessor name. No I/O at all."
  }

  test "D11 no core module calls an HTTP client, a socket or a shell" do
    hits =
      for {path, source} <- sources(),
          client <- @clients,
          String.contains?(source, client),
          do: "#{path}: #{client}"

    assert hits == [],
           "the core is documented as sending nothing anywhere on its own, and now it does:\n  " <>
             Enum.join(hits, "\n  ")
  end

  test "D11 every apply/3 in lib/ names a target this test knows the bound on" do
    # The scan above finds a call site by its module name, so an `apply/3` whose
    # module is computed at run time is a hole in it. This is not "no apply/3":
    # dispatching to a configured module is how `AuroraMeter.Storage`,
    # `AuroraMeter.Clock` and the host callbacks work, and forbidding it would
    # forbid the library's own seams. What it asserts is that the hole is never
    # silent: a new dynamic target fails here until somebody writes down what
    # bounds it.
    unknown =
      for {path, calls} <- apply_calls(),
          {line, target} <- calls,
          not Map.has_key?(@dynamic_targets, target),
          do: "#{path}:#{line} apply(#{target}, ...)"

    assert unknown == [],
           "an apply/3 in lib/ names a target this test does not know about, so the scan " <>
             "above can no longer say where it goes:\n  " <> Enum.join(unknown, "\n  ")
  end

  test "D11 every bound named on a dynamic dispatch is a behaviour of this package" do
    # The seams dispatch to a module the HOST configures, which no test here can
    # enumerate. What it can assert is that each one is bounded by a behaviour
    # this package defines, so a host swapping one in is running its own code
    # knowingly rather than being handed an outbound client by Aurora Meter.
    for behaviour <- [AuroraMeter.Storage, AuroraMeter.Clock, AuroraMeter.Billing.Provider] do
      assert function_exported?(behaviour, :behaviour_info, 1),
             "#{inspect(behaviour)} is named as a bound on a dynamic dispatch and is not a " <>
               "behaviour"
    end
  end

  test "D11 the core declares no HTTP or socket dependency" do
    deps =
      "mix.exs"
      |> File.read!()
      |> then(&Regex.scan(~r/\{:([a-z_0-9]+),/, &1))
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()

    outbound = ~w(finch req httpoison mint tesla hackney mojito gun websockex)

    assert Enum.filter(deps, &(&1 in outbound)) == [],
           "core declared an HTTP dependency; a dependency is not a call site, but it is " <>
             "how one arrives"
  end

  test "D11 the library attaches no telemetry handler of its own" do
    # G08 bullet 2 asks for attach and detach tests that leave no handler
    # leaks. The cheapest version of that claim is the one this package can
    # make absolutely: it attaches nothing, ever, so there is nothing to leak.
    # Handlers are the host's, and an exporter or a bridge that attached one at
    # boot would be the library deciding what leaves the node.
    hits =
      for {path, source} <- sources(),
          fragment <- [":telemetry.attach(", ":telemetry.attach_many("],
          String.contains?(source, fragment),
          do: "#{path}: #{fragment}"

    assert hits == [],
           "lib/ attaches a telemetry handler, so the library now owns a subscription " <>
             "the host did not ask for: " <> inspect(hits)

    # What this deliberately does NOT do is assert on `:telemetry.list_handlers/1`
    # at run time. Half this suite attaches a handler for the length of a test,
    # several of those modules are `async: true`, and an assertion about the
    # global handler table taken from inside one of them is an assertion about
    # which other test happened to be running. The claim worth making is about
    # the library's own source, and that is the one above.
  end

  # Every `apply(module, fun, args)` in `lib/`, with the module as the source
  # spells it, read from the AST. Text would also match this package's own
  # `AuroraMeter.Cluster.apply/3` and its `@spec`, neither of which is a dynamic
  # dispatch, and a check that reported those would be ignored within a week.
  defp apply_calls do
    for path <- Path.wildcard("lib/**/*.ex") do
      {:ok, tree} = Code.string_to_quoted(File.read!(path))

      {_tree, calls} =
        Macro.prewalk(tree, [], fn
          # Attributes carry `@spec apply(...)`, which is a type and not a call.
          {:@, _, _}, acc ->
            {nil, acc}

          # A `def apply(...)` head is a definition of a function with that
          # name, not a use of `Kernel.apply/3`. Traverse only the body.
          {kind, _, [_head, body]}, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
            {body, acc}

          {:apply, meta, [target, _fun, args]} = node, acc when is_list(args) ->
            {node, [{meta[:line], Macro.to_string(target)} | acc]}

          node, acc ->
            {node, acc}
        end)

      {path, Enum.reverse(calls)}
    end
  end

  defp sources do
    for path <- Path.wildcard("lib/**/*.ex") do
      source =
        path
        |> File.read!()
        |> String.replace(~r/"""[\s\S]*?"""/, "")
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
        |> Enum.join("\n")

      {path, source}
    end
  end
end
