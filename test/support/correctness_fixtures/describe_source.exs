# credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
#
# The check is correct in general and is deliberately disabled here, not
# repo-wide: this file exists to be READ AS TEXT by the correctness index
# parser, so it has to look exactly like a real test file, `use ExUnit.Case`
# included. It is never compiled and never run (the suite's wildcard is
# `test/**/*_test.exs`, which it does not match), so the condition the check
# warns about, a test file that silently never runs, cannot apply to it.
defmodule AuroraMeter.CorrectnessFixtures.DescribeSource do
  @moduledoc false
  # A fixture read as text by `AuroraMeter.CorrectnessIndexTest`. It is never
  # compiled and never run: the suite's wildcard is `test/**/*_test.exs` and this
  # file does not match it. It exists so the parser can be tested against a
  # describe block, a top-level test and an interpolated name without touching a
  # real test file.
  use ExUnit.Case, async: true

  describe "grouped behaviour" do
    test "it holds" do
      assert true
    end
  end

  test "it stands alone" do
    assert true
  end

  for n <- 1..2 do
    test "I09 #{n}" do
      assert n > 0
    end
  end
end
