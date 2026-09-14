defmodule AuroraMeter.Migration.ConcurrentVersionError do
  @moduledoc """
  Raised by `AuroraMeter.Migration.up/1` when a version that must run outside a
  DDL transaction is asked to run alongside other versions.

  Core version 8 creates a unique index `CONCURRENTLY`, which Postgres refuses
  inside a transaction block. It therefore needs a host migration of its own
  carrying `@disable_ddl_transaction true` and `@disable_migration_lock true`,
  which `mix aurora_meter.gen.migration` generates as a separate file.

  The escape is `concurrently: false`, which builds the index inside the
  transaction. That is right for a fresh install and for an install whose
  events table is small enough to lock; it is wrong for a live table with a
  large number of rows in it.
  """

  @type t :: %__MODULE__{
          versions: [pos_integer()],
          concurrent: [pos_integer()],
          message: String.t()
        }

  defexception [:versions, :concurrent, :message]

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    versions = Keyword.fetch!(opts, :versions)
    concurrent = Keyword.fetch!(opts, :concurrent)

    %__MODULE__{
      versions: versions,
      concurrent: concurrent,
      message: build_message(versions, concurrent)
    }
  end

  @spec build_message([pos_integer()], [pos_integer()]) :: String.t()
  defp build_message(versions, concurrent) do
    list = Enum.map_join(concurrent, ", ", &Integer.to_string/1)

    "Aurora Meter schema #{plural(concurrent)} #{list} creates an index CONCURRENTLY, " <>
      "which Postgres refuses inside a transaction block, so it cannot share a host " <>
      "migration with the other versions in #{inspect(versions)}. Generate it into its own " <>
      "file with `mix aurora_meter.gen.migration`, which emits @disable_ddl_transaction " <>
      "true and @disable_migration_lock true on it. On a fresh install, or one whose " <>
      "aurora_meter_events table is small enough to lock, pass `concurrently: false` " <>
      "instead and the index is built inside the transaction."
  end

  @spec plural([pos_integer()]) :: String.t()
  defp plural([_one]), do: "version"
  defp plural(_many), do: "versions"
end

defmodule AuroraMeter.Migration.DataLossError do
  @moduledoc """
  Raised by `AuroraMeter.Migration.down/1` when the range holds a version whose
  `down` destroys a commercial fact.

  `down` is not a rollback. Version 7's `down` removes `event_id` and
  `payload_hash`, which are the identity of every recorded fact, and drops
  `aurora_meter_event_totals` and `aurora_meter_checkpoints` with them. The
  supported recovery from a bad upgrade is the backup taken before it.

  Pass `confirm_data_loss: true` when the loss is what you intend.
  """

  @type t :: %__MODULE__{
          versions: [pos_integer()],
          destructive: [pos_integer()],
          message: String.t()
        }

  defexception [:versions, :destructive, :message]

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    versions = Keyword.fetch!(opts, :versions)
    destructive = Keyword.fetch!(opts, :destructive)

    %__MODULE__{
      versions: versions,
      destructive: destructive,
      message: build_message(destructive)
    }
  end

  @spec build_message([pos_integer()]) :: String.t()
  defp build_message(destructive) do
    list = Enum.map_join(destructive, ", ", &Integer.to_string/1)

    "the down step of Aurora Meter schema #{plural(destructive)} #{list} destroys " <>
      "commercial state that no later step can rebuild: caller event identity, the payload " <>
      "hashes that tell a retry from a different fact, and the projection totals. A down " <>
      "step is not a rollback; the supported recovery from a bad upgrade is the backup " <>
      "taken before it. Pass `confirm_data_loss: true` if destroying it is what you mean " <>
      "to do."
  end

  @spec plural([pos_integer()]) :: String.t()
  defp plural([_one]), do: "version"
  defp plural(_many), do: "versions"
end

defmodule AuroraMeter.Migration.BackfillIncompleteError do
  @moduledoc """
  Raised by core schema version 8 while any `aurora_meter_events` row still has
  a null `event_id`.

  Version 8 promotes `event_id` to `NOT NULL` behind a unique index on
  `(tenant_key, event_id)`. Both need every row to carry an identity, which for
  rows written by 0.4.x is given by `mix aurora_meter.events.backfill`.

  A non-zero count after a completed backfill means an 0.4.x node is still
  writing durable events through `AuroraMeter.track/4`. That is the one
  quiescence point in the V1 upgrade: stop those writers, run the backfill
  again, then run version 8. Refusing is the safe failure; a partial index
  would not be.
  """

  @type t :: %__MODULE__{remaining: non_neg_integer(), message: String.t()}

  defexception [:remaining, :message]

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    remaining = Keyword.fetch!(opts, :remaining)

    %__MODULE__{remaining: remaining, message: build_message(remaining)}
  end

  @spec build_message(non_neg_integer()) :: String.t()
  defp build_message(remaining) do
    "Aurora Meter schema version 8 cannot run: #{remaining} #{rows(remaining)} in " <>
      "aurora_meter_events still #{has(remaining)} a null event_id. Run " <>
      "`mix aurora_meter.events.backfill` and re-run this migration. If the count keeps " <>
      "growing, an 0.4.x node is still calling AuroraMeter.track/4 with durable: true: " <>
      "stop those writers first, then backfill."
  end

  @spec rows(non_neg_integer()) :: String.t()
  defp rows(1), do: "row"
  defp rows(_many), do: "rows"

  @spec has(non_neg_integer()) :: String.t()
  defp has(1), do: "has"
  defp has(_many), do: "have"
end
