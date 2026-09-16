defmodule AuroraMeter.Schema.PlanVersion do
  @moduledoc """
  One snapshot of a plan version's commercial content.

  Written only by `AuroraMeter.Plans.register!/0`, from compiled code, and never
  updated: a row is immutable once inserted. The table is **not** a plan
  catalogue and nothing reads it to decide what a plan is. Code is authoritative
  (`v1-release.md` 07.02); the snapshot exists so a subscription or an event
  that names a version whose block has been deleted from the host's plans module
  is still interpretable.

  `fingerprint` is the sha256 of the canonical form `AuroraMeter.Plans.Snapshot`
  renders a plan's commercial content into, and
  `definition` is the same content in a decodable jsonb shape.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "aurora_meter_plan_versions" do
    field :plan_id, :string
    field :version, :string
    field :fingerprint, :binary
    field :definition, :map, default: %{}
    field :effective_at, :utc_datetime
    field :first_seen_at, :utc_datetime_usec
  end

  @castable ~w(plan_id version fingerprint definition effective_at first_seen_at)a

  @doc "Builds a changeset for a plan version snapshot."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(plan_version, attrs) do
    plan_version
    |> cast(attrs, @castable)
    # `first_seen_at` is **not** required: the column carries a
    # `clock_timestamp()` default from core schema version 10, and a caller that
    # omits it is asking the database to stamp the row, which is the form
    # `architecture-map.md` section 3 asks for. Requiring it here would force
    # every caller to read a clock and write it back.
    |> validate_required([:plan_id, :version, :fingerprint])
    |> validate_length(:plan_id, min: 1, max: 128, count: :bytes)
    |> validate_length(:version, min: 1, max: 32, count: :bytes)
    |> validate_fingerprint()
    |> unique_constraint([:plan_id, :version],
      name: :aurora_meter_plan_versions_plan_id_version_index
    )
  end

  defp validate_fingerprint(changeset) do
    validate_change(changeset, :fingerprint, fn :fingerprint, value ->
      if byte_size(value) == 32, do: [], else: [fingerprint: "must be 32 bytes of sha256"]
    end)
  end
end
