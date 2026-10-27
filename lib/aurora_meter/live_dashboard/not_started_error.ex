# Its own file rather than the tail of sections.ex: `Sections.class_for/1`
# pattern matches on this struct, and Elixir 1.15 refuses a struct pattern for a
# module defined later in the same file, so 1.0.0 did not compile on the
# documented 1.15 floor.
defmodule AuroraMeter.LiveDashboard.NotStartedError do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch. A host mounts
  `AuroraMeter.LiveDashboard.Page`; this is what that page is built from.

  Raised inside `AuroraMeter.LiveDashboard.Sections` when a node-local table or
  process the section reads is absent, which means the supervision tree is not
  running. `read/1` converts it into `{:unavailable, :not_started}`; it is never
  raised out of this module.
  """

  defexception [:table]

  @impl Exception
  def message(%{table: table}),
    do: "the ETS table #{inspect(table)} does not exist, so AuroraMeter is not started"
end
