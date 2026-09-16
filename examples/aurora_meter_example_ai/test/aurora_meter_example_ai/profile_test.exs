defmodule AuroraMeterExampleAi.ProfileTest do
  @moduledoc """
  What the core profile must not contain.

  The core profile is MIT, runs with Elixir and Postgres and nothing else, and
  names no commercial module and no provider. `09d` adds a Pro profile on top of
  this tree; until it does, and after it does, nothing outside its own guarded
  modules may mention `AuroraMeter.Pro`.
  """
  use ExUnit.Case, async: true

  @sources Path.wildcard("lib/**/*.{ex,exs}") ++ Path.wildcard("config/*.exs")

  test "the file list is not empty" do
    # The instrument's own floor. A wildcard that matched nothing would make
    # every test below pass on an empty list, which is X325's family.
    assert length(@sources) > 20, "only #{length(@sources)} source files were found"
  end

  test "no source in the core profile names a Pro module" do
    offenders = grep(~r/AuroraMeter\.Pro\b/)

    assert offenders == [],
           "the core profile names a commercial module:\n" <> Enum.join(offenders, "\n")
  end

  test "no source in the core profile names a payment provider" do
    offenders = grep(~r/\b(Stripe|stripe|sk_live|sk_test|pk_live|whsec_)\b/)

    assert offenders == [],
           "the core profile names a payment provider:\n" <> Enum.join(offenders, "\n")
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

  test "the sample declares the aurora_meter path dependency and no commercial one" do
    mix_exs = File.read!("mix.exs")
    assert mix_exs =~ ~s|{:aurora_meter, path: "../.."}|
    refute mix_exs =~ "aurora_meter_pro"
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
end
