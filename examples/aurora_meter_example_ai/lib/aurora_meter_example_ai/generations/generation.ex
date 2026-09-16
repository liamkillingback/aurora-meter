defmodule AuroraMeterExampleAi.Generations.Generation do
  @moduledoc """
  One generation this application ran, and what it cost.

  The primary key **is** the client's request id. That is not a shortcut: it is
  what makes a double submit a primary key violation rather than a second
  charge, and it is the same string used as the Aurora Meter event identity and
  as the credit hold reference, so the three facts about one request can always
  be lined up.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "generations" do
    field :kind, :string
    field :prompt, :string
    field :model, :string
    field :status, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :output, :string
    field :cost_micros, :integer
    field :estimate_micros, :integer
    field :event_id, :string
    field :hold_reference, :string
    field :settled_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :org, AuroraMeterExampleAi.Orgs.Org
    belongs_to :user, AuroraMeterExampleAi.Accounts.User
  end

  @fields ~w(id org_id user_id kind prompt model status prompt_tokens completion_tokens
             output cost_micros estimate_micros event_id hold_reference settled_at
             inserted_at)a

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(generation, attrs) do
    generation
    |> cast(attrs, @fields)
    |> validate_required([:id, :org_id, :user_id, :kind, :prompt, :model, :status, :inserted_at])
    |> validate_inclusion(:kind, ["text", "image"])
    |> validate_inclusion(:status, ["settled", "released", "rejected"])
    |> unique_constraint(:id, name: "generations_pkey")
    |> unique_constraint([:org_id, :event_id], name: :generations_org_id_event_id_index)
  end

  @doc """
  The total tokens a settled generation used, or `nil`.

  ## Examples

      iex> AuroraMeterExampleAi.Generations.Generation.total_tokens(
      ...>   %AuroraMeterExampleAi.Generations.Generation{prompt_tokens: 4, completion_tokens: 20})
      24

  """
  @spec total_tokens(t()) :: non_neg_integer() | nil
  def total_tokens(%__MODULE__{prompt_tokens: p, completion_tokens: c})
      when is_integer(p) and is_integer(c),
      do: p + c

  def total_tokens(%__MODULE__{}), do: nil
end
