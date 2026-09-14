# A fixture for AuroraMeter.DocsClaimsTest's parser, not a test module. It is
# never loaded or run: the parser reads it as text and turns it into AST.
#
# It exists because of open-findings.md X84. The obvious way to check "the
# documentation names a test, prove the test exists" is to search the test
# sources for the name. That check passes for a test that has been renamed or
# deleted while its old name survives in a moduledoc or a comment, which is to
# say it validates the documentation against itself. Two such mentions are
# below. Exactly one real test is defined.
defmodule AuroraMeter.ClaimsFixtures.DocstringOnly do
  @moduledoc """
  Names a test it does not define:

      test "named only in the moduledoc" do
        :ok
      end

  A textual search finds that. A parser must not.
  """

  # test "named only in a comment" do

  describe "a group" do
    @doc """
    And a function doc that also writes:

        test "named only in the moduledoc"
    """
    test "this one is genuinely defined" do
      :ok
    end
  end
end
