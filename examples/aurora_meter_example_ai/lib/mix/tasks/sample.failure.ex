defmodule Mix.Tasks.Sample.Failure do
  @shortdoc "Runs one of the eight failure recipes and shows what it left behind"

  @moduledoc """
  Triggers a real failure, reads back the real rows, and prints what survived.

      mix sample.failure                       # list the recipes
      mix sample.failure insufficient_balance  # run one
      mix sample.failure all                   # run every core-profile recipe
      mix sample.failure exporter_timeout --no-recovery
      mix sample.failure --check               # re-assert the last run's JSON

  Every run writes `tmp/sample-failures/<name>.json` with the observed figures,
  through a redaction filter, so a reader can look at the state at leisure and
  so `--check` can re-assert it without triggering anything again.

  ## This runs against your development database

  Each recipe makes its own organisation with a unique slug and touches nothing
  else, so running one never disturbs `acme` or `globex`. It is still a
  database that accumulates: `mix ecto.reset` starts again from nothing.

  ## The recipes

  Seven need nothing but Elixir and Postgres. One, `customer_cancellation`,
  needs the Pro profile and a Stripe test-mode account, and it **aborts by
  name** without them rather than degrading into a simulation.

  `docs/failures.md` is the same eight recipes written out, with the documented
  end state of each. `test/sample_failure_test.exs` asserts that end state, so
  the document cannot drift from the software without the suite going red.
  """
  use Mix.Task

  alias AuroraMeterExampleAi.Failures
  alias AuroraMeterExampleAi.Redact

  @out "tmp/sample-failures"

  @impl Mix.Task
  def run(args) do
    # Before `app.start`, deliberately: the development environment logs every
    # query at `:debug`, the boot alone makes dozens, and the report IS the
    # output here. A reader who wants the SQL sets
    # `AURORA_SAMPLE_FAILURE_LOG=debug`.
    Logger.configure(level: log_level())

    Mix.Task.run("app.start")

    {opts, rest, _} =
      OptionParser.parse(args, switches: [recovery: :boolean, check: :boolean, quiet: :boolean])

    cond do
      opts[:check] -> check()
      rest == [] -> list()
      rest == ["all"] -> Enum.each(core_names(), &one(&1, opts))
      true -> Enum.each(rest, &one(&1, opts))
    end
  end

  defp log_level do
    case System.get_env("AURORA_SAMPLE_FAILURE_LOG") do
      "debug" -> :debug
      "info" -> :info
      _default -> :warning
    end
  end

  defp core_names do
    Failures.recipes() |> Enum.filter(&(&1.profile == :core)) |> Enum.map(& &1.name)
  end

  defp list do
    Mix.shell().info("""

    The failure recipes. Each one triggers a real failure and shows the rows.

    """)

    Enum.each(Failures.recipes(), fn recipe ->
      Mix.shell().info(
        "  #{String.pad_trailing(recipe.name, 24)} #{recipe.profile}  #{recipe.shows}"
      )
    end)

    Mix.shell().info("""

      mix sample.failure <name>     run one
      mix sample.failure all        run every core-profile recipe

    docs/failures.md is the written version of the same eight.
    """)
  end

  defp one(name, opts) do
    apply_recovery = Keyword.get(opts, :recovery, true)

    case Failures.run(name, apply_recovery: apply_recovery) do
      {:ok, report} ->
        print(report, opts)
        write(report)

      {:error, {:unknown_recipe, given, known}} ->
        Mix.raise("""
        There is no recipe called #{inspect(given)}.

        Known recipes: #{Enum.join(known, ", ")}.
        """)
    end
  end

  defp print(report, opts) do
    unless opts[:quiet] do
      Mix.shell().info("""

      ================================================================
      #{report.recipe}   (profile: #{report.profile}, tenant: #{report.tenant})
      ================================================================
      """)

      section("Setup", report[:setup])
      section("Trigger", report[:trigger])
      section("What the application shows", report[:application])
      section("What the database shows", report[:database])
      section("What the ledger shows", report[:ledger])
      section("Recovery", report[:recovery])
      section("What stays uncertain", report[:uncertain])

      Enum.each([:projection, :quantities, :effects, :note], fn key ->
        if report[key], do: section(Atom.to_string(key), report[key])
      end)
    end
  end

  defp section(_title, nil), do: :ok

  defp section(title, []) do
    Mix.shell().info("## #{title}\n\n  (nothing, and that is the answer)\n")
  end

  defp section(title, value) do
    Mix.shell().info("## #{title}\n")
    Mix.shell().info(indent(value))
    Mix.shell().info("")
  end

  defp indent(value) when is_binary(value), do: "  " <> Redact.text(value)

  defp indent(value) when is_list(value) do
    Enum.map_join(value, "\n", fn item -> "  - " <> Redact.text(to_string_safe(item)) end)
  end

  defp indent(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join("\n", fn {k, v} -> "  #{k}: " <> Redact.text(to_string_safe(v)) end)
  end

  defp indent(value), do: "  " <> Redact.text(inspect(value))

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value, limit: :infinity, printable_limit: 4_000)

  # Every byte that reaches disk goes through the redaction filter, even though
  # nothing in a core-profile recipe can carry a credential. The filter is
  # cheap and the alternative is deciding, per field, whether this one might:
  # that decision is made once here and never again.
  defp write(report) do
    File.mkdir_p!(@out)
    path = Path.join(@out, "#{report.recipe}.json")

    json =
      report
      |> jsonable()
      |> Jason.encode!(pretty: true)
      |> Redact.text()

    File.write!(path, json)
    Mix.shell().info("  written: #{path}")
  end

  defp jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp jsonable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp jsonable(%Date{} = value), do: Date.to_iso8601(value)

  defp jsonable(%_struct{} = value),
    do: value |> Map.from_struct() |> Map.drop([:__meta__]) |> jsonable()

  defp jsonable(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)

  defp jsonable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp jsonable(value) when is_tuple(value), do: value |> Tuple.to_list() |> jsonable()
  defp jsonable(value), do: value

  # `--check` re-asserts the written JSON without triggering anything. It is
  # what a reader runs after they have looked at the rows themselves, and it is
  # deliberately not a re-run: a recipe that has to be re-triggered to be
  # checked cannot be inspected at leisure.
  defp check do
    files = Path.wildcard(Path.join(@out, "*.json"))

    if files == [] do
      Mix.raise("""
      There is nothing to check: #{@out} is empty.

      Run `mix sample.failure all` first.
      """)
    end

    Enum.each(files, fn path ->
      report = path |> File.read!() |> Jason.decode!()
      problems = problems(report)

      if problems == [] do
        Mix.shell().info("  ok    #{Path.basename(path)}  (#{report["recipe"]}, #{report["at"]})")
      else
        Mix.shell().error("  BAD   #{Path.basename(path)}: #{Enum.join(problems, "; ")}")
      end
    end)
  end

  defp problems(report) do
    []
    |> check_present(report, "recipe")
    |> check_present(report, "at")
    |> check_present(report, "recovery")
    |> check_no_row_edit(report)
  end

  defp check_present(problems, report, key) do
    if Map.has_key?(report, key), do: problems, else: ["missing #{key}" | problems]
  end

  # L09d-4, asserted over the written evidence as well as over the document: a
  # recovery step is a named function, never a row edit.
  defp check_no_row_edit(problems, report) do
    command = get_in(report, ["recovery", "command"]) || ""

    if Regex.match?(~r/\b(UPDATE|INSERT|DELETE)\b/, command) do
      ["the recovery command contains a row edit" | problems]
    else
      problems
    end
  end
end
