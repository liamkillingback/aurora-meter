defmodule AuroraMeter.PackagingTest do
  @moduledoc """
  What the Hex archive contains, asserted rather than assumed.

  `mix.exs` declares `package[:files]` as an explicit allow list, so `examples/`,
  `demo/`, `docs/`, `priv/` and `test/` are excluded by construction rather than
  by an ignore rule. That is the right shape and it is also a property of one
  `~w` literal that nothing tested until this file existed: adding `"examples"`
  to it would ship a whole second Phoenix application, with its own `deps` and
  `_build` if anyone had built it, and the first anyone would know is the upload
  size.

  I21: the sample is the artifact build units `09e` and `11c` build from a
  candidate archive, and it is not in the archive.
  """
  use ExUnit.Case, async: true

  @files Mix.Project.config()[:package][:files]

  test "the file list is an explicit allow list" do
    assert is_list(@files) and @files != []

    # The instrument's floor. An empty or missing list would make every
    # assertion below pass.
    assert "lib" in @files
    assert "mix.exs" in @files
  end

  test "no entry ships the sample application" do
    offenders = Enum.filter(@files, &String.contains?(&1, "examples"))
    assert offenders == [], "package.files ships the sample: #{inspect(offenders)}"
  end

  test "no entry ships the historical demo project" do
    offenders = Enum.filter(@files, &String.contains?(&1, "demo"))
    assert offenders == [], "package.files ships demo/: #{inspect(offenders)}"
  end

  test "no entry ships the test suite, the docs or priv" do
    offenders = Enum.filter(@files, &(&1 in ~w(test docs priv doc cover _build deps)))
    assert offenders == [], "package.files ships something it should not: #{inspect(offenders)}"
  end

  test "the scan can see a forbidden entry" do
    # The control. Four assertions above are negatives over the same filter; if
    # the filter could not match, all four would pass on a list that shipped
    # everything.
    planted = @files ++ ["examples", "demo", "test"]

    assert Enum.filter(planted, &String.contains?(&1, "examples")) == ["examples"]
    assert Enum.filter(planted, &String.contains?(&1, "demo")) == ["demo"]
    assert Enum.filter(planted, &(&1 in ~w(test docs priv))) == ["test"]
  end

  test "the sample exists on disk and is outside the archive" do
    # Both halves matter. If the sample did not exist, the exclusion tests above
    # would be guarding nothing; if it existed inside `lib/`, the allow list
    # would ship it.
    assert File.dir?("examples/aurora_meter_example_ai"),
           "the sample is missing, so the exclusion this file asserts is vacuous"

    refute File.exists?("lib/aurora_meter_example_ai")
  end
end
