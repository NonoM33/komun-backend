defmodule KomunBackend.Auth.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string
    field :token_prefix, :string

    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:name, :token_hash, :token_prefix, :user_id, :expires_at])
    |> validate_required([:name, :token_hash, :token_prefix, :user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:token_hash)
  end
end
