# A fixture for AuroraMeter.HouseStyleTest's Elixir scanner, not a test module
# and never loaded: `elixirc_paths(:test)` compiles `.ex` only, and the scanner
# reads this file as AST.
#
# It carries one dash of every kind the scanner has to tell apart. Two must be
# reported and three must not, and asserting both halves is what makes the
# guard discriminate rather than merely stay quiet.
defmodule AuroraMeter.StyleFixtures.Dashes do
  @moduledoc """
  REPORT-moduledoc: an em dash in doc prose — hexdocs renders this exactly as it
  renders a guide, so it is copy and must be reported.

  SILENT-docspan: a dash inside a code span, `a — b`, is a sample.

      # SILENT-docfence: an indented sample — indented is how a doc string
      # writes a code block, and a sample is not prose
      :ok
  """

  # SILENT-comment: an em dash in a comment — a comment is not copy, and a guard
  # that fires on one is a guard people learn to route around
  # (AuroraMeter.EvidenceWritesTest was tripped by exactly this).

  @doc false
  def label do
    "REPORT-string: an en dash in a rendered string – a customer can see this"
  end
end
