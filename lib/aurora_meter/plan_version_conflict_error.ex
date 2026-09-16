defmodule AuroraMeter.PlanVersionConflictError do
  @moduledoc """
  Raised by `AuroraMeter.Plans.register!/0` when a compiled plan version's
  commercial content differs from the snapshot already stored for it.

  This is the whole of invariant I17 in one exception. A plan version is
  immutable: editing `price 2_000` to `price 3_000` inside `plan :pro` changes
  what every tenant on `:pro` version `"1"` is charged, retroactively and
  silently, and no amount of testing downstream can recover the fact that they
  were on the old contract. The registry refuses the boot instead.

  The remedy is always the same and the message says it: publish the change as a
  new version.

      plan :pro, version: "2", effective_at: ~U[2026-10-01 00:00:00Z] do
        price 3_000
      end

  `conflicts` is a list of maps with `:plan_id`, `:version`,
  `:stored_fingerprint` and `:compiled_fingerprint`. Rescue it in a release task
  if a host wants to report rather than crash; do not retry it, because a retry
  compares the same two values and reaches the same answer.

  Configuration `plan_version_conflict: :warn` logs the same message through
  `Logger.error/1` and lets the boot continue. That is the default in the 0.5.x
  transition release so an upgrading host sees the problem before it becomes a
  failed deploy, and `:raise` is the default from 1.0.
  """

  alias AuroraMeter.Plans.Snapshot

  @type conflict :: %{
          plan_id: String.t(),
          version: String.t(),
          stored_fingerprint: binary() | nil,
          compiled_fingerprint: binary() | nil
        }

  defexception [:conflicts, :message]

  @type t :: %__MODULE__{conflicts: [conflict()], message: String.t()}

  @impl true
  def exception(opts) do
    conflicts = Keyword.fetch!(opts, :conflicts)
    %__MODULE__{conflicts: conflicts, message: format(conflicts)}
  end

  @doc """
  The operator-facing message for a list of conflicts.

  Public because `plan_version_conflict: :warn` logs exactly this string rather
  than a second, drifting copy of it.

  It is `format/1` and not `message/1` because `message/1` is the `Exception`
  callback `defexception` generates. Defining a one-argument `message/1` over a
  **list** here shadows it, and `Exception.message/1` on the struct then raises
  a `Protocol.UndefinedError` instead of rendering the exception, which is a
  failure that only shows up at the moment somebody needs to read the error.
  """
  @spec format([conflict()]) :: String.t()
  def format(conflicts) do
    lines =
      Enum.map_join(conflicts, "\n", fn conflict ->
        "  * plan #{conflict.plan_id} version #{conflict.version}: stored " <>
          "#{Snapshot.short(conflict.stored_fingerprint)}, compiled " <>
          "#{Snapshot.short(conflict.compiled_fingerprint)}"
      end)

    example = List.first(conflicts)

    "Aurora Meter refuses to reprice an existing plan version. The commercial " <>
      "content of #{length(conflicts)} compiled plan version(s) differs from the " <>
      "snapshot registered for them:\n\n" <>
      lines <>
      "\n\nEvery subscription pinned to one of those versions was sold the stored " <>
      "definition. Publish the change as a new version instead, for example:\n\n" <>
      "    plan :#{example.plan_id}, version: \"#{next_version(example.version)}\", " <>
      "effective_at: ~U[2026-01-01 00:00:00Z] do\n      # the new price and limits\n    end\n\n" <>
      "Or revert the edit. Setting `config :aurora_meter, plan_version_conflict: :warn` " <>
      "logs this instead of raising, which is the transition-release default and not a fix. " <>
      "The stored definitions are in aurora_meter_plan_versions:\n\n" <>
      "    SELECT plan_id, version, encode(fingerprint, 'hex'), definition\n" <>
      "    FROM aurora_meter_plan_versions ORDER BY plan_id, version;\n"
  end

  # A suggestion, not a rule: a host that versions "2024-01" gets "2024-01-next"
  # and will write its own, and a host on "1" gets "2".
  defp next_version(version) do
    case Integer.parse(version) do
      {number, ""} -> Integer.to_string(number + 1)
      _other -> version <> "-next"
    end
  end
end
