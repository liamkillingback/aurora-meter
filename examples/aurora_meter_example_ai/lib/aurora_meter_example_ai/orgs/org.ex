defmodule AuroraMeterExampleAi.Orgs.Org do
  @moduledoc """
  An organisation: the thing this application bills, meters and isolates by.

  It is the term handed to every Aurora Meter call, through
  `AuroraMeterExampleAi.Tenancy`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "orgs" do
    field :name, :string
    field :slug, :string
    field :api_key, :string

    has_many :users, AuroraMeterExampleAi.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must be lower case letters, digits and hyphens"
    )
    |> put_api_key()
    |> unique_constraint(:slug)
    |> unique_constraint(:api_key)
  end

  defp put_api_key(changeset) do
    case get_field(changeset, :api_key) do
      nil -> put_change(changeset, :api_key, generate_api_key())
      _key -> changeset
    end
  end

  @doc "A fresh API key. 24 random bytes, URL safe, with a visible prefix."
  @spec generate_api_key() :: String.t()
  def generate_api_key do
    "sample_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end
end
