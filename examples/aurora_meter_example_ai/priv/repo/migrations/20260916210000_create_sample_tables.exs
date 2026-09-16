defmodule AuroraMeterExampleAi.Repo.Migrations.CreateSampleTables do
  @moduledoc """
  The sample application's own tables.

  It runs after `AddAuroraMeter`, which is the migration
  `mix aurora_meter.install` generated. Aurora Meter owns its own tables and
  this application owns these; nothing here alters a table with an
  `aurora_meter_` prefix, and `generations.event_id` is deliberately **not** a
  foreign key onto `aurora_meter_events` (see the comment on it).
  """
  use Ecto.Migration

  def change do
    create table(:orgs) do
      add :name, :string, null: false
      add :slug, :citext, null: false
      # A random secret, not a derived one. The `/api/generate` route compares
      # it in constant time. A real application stores a hash of it and shows
      # the plaintext once; this one stores the plaintext because the sample
      # has to be able to print it for you, and says so where it prints it.
      add :api_key, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:orgs, [:slug])
    create unique_index(:orgs, [:api_key])

    # The generated users table predates organisations. `on_delete: :restrict`
    # rather than `:delete_all`: deleting an organisation that still has members
    # should be refused, not silently cascade into the people.
    alter table(:users) do
      add :org_id, references(:orgs, on_delete: :restrict)
      add :role, :string, null: false, default: "member"
    end

    create index(:users, [:org_id])

    create constraint(:users, :users_role_check, check: "role in ('owner', 'member')")

    create table(:generations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :kind, :string, null: false
      add :prompt, :text, null: false
      add :model, :string, null: false
      add :status, :string, null: false
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :output, :text
      add :cost_micros, :bigint
      add :estimate_micros, :bigint

      # A loose reference to `aurora_meter_events.event_id`, on purpose. The
      # library owns that table: a foreign key from here would make this
      # application's schema a constraint on the library's, and the library's
      # retention policy could then be blocked by a sample row. What holds the
      # two together is the identity, which is the same string on both sides.
      add :event_id, :string
      add :hold_reference, :string

      add :inserted_at, :utc_datetime_usec, null: false
      add :settled_at, :utc_datetime_usec
    end

    create index(:generations, [:org_id, "inserted_at DESC"])

    create unique_index(:generations, [:org_id, :event_id],
             where: "event_id is not null",
             name: :generations_org_id_event_id_index
           )

    # Three states, all of them reachable from the browser. `settled` is the
    # normal one; `rejected` is a generation whose work raised, which is billed
    # nothing at all; `released` is one whose work succeeded but whose durable
    # record could not be written, so the hold was given back. The build plan
    # for this unit also listed `pending`, and it is not here: this application
    # writes the row after the outcome is known, so there is no moment at which
    # a row is pending, and a state nothing can put a row into is a state that
    # gets read as if it meant something.
    create constraint(:generations, :generations_status_check,
             check: "status in ('settled', 'released', 'rejected')"
           )

    create constraint(:generations, :generations_cost_check,
             check: "cost_micros is null or cost_micros >= 0"
           )

    create constraint(:generations, :generations_kind_check, check: "kind in ('text', 'image')")

    # The host-owned outbox. `AuroraMeter.record/4` calls
    # `AuroraMeterExampleAi.SampleOutbox.enqueue/2` inside the transaction that
    # writes the event, and that callback inserts one row here. An intent
    # staged in the same commit as the fact cannot be lost and cannot exist for
    # a fact that rolled back.
    create table(:sample_outbox_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, :string, null: false
      add :tenant_key, :string, null: false
      add :feature, :string, null: false
      add :quantity, :bigint, null: false
      # Second precision, not microsecond: a period start is a boundary the
      # library computed, and `AuroraMeter.Event.period_start` carries it at
      # second precision. A `:utc_datetime_usec` column here raises
      # `ArgumentError` on the first event, inside the record transaction, and
      # comes back to the caller as
      # `{:error, {:unavailable, {:outbox, {:raised, ArgumentError, ...}}}}`.
      add :period_start, :utc_datetime, null: false
      add :payload, :map, null: false, default: %{}
      add :state, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_outcome, :string
      add :provider_ref, :string
      add :next_attempt_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sample_outbox_items, [:tenant_key, :event_id])
    create index(:sample_outbox_items, [:state, :next_attempt_at])

    # `claimed` is in the list because the drainer claims a batch in one
    # statement before it delivers it: a row that is being delivered right now
    # is neither pending nor finished, and a state machine with no word for
    # "in flight" cannot survive the worker dying mid-batch.
    create constraint(:sample_outbox_items, :sample_outbox_items_state_check,
             check:
               "state in ('pending', 'claimed', 'delivered', 'uncertain', 'rejected', 'skipped')"
           )

    create constraint(:sample_outbox_items, :sample_outbox_items_quantity_check,
             check: "quantity > 0"
           )

    create constraint(:sample_outbox_items, :sample_outbox_items_attempts_check,
             check: "attempts >= 0"
           )
  end
end
