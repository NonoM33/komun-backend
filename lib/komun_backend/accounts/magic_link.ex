defmodule KomunBackend.Accounts.MagicLink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @token_length 32
  @ttl_minutes 15

  schema "magic_links" do
    field :token_hash, :string
    field :email, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(magic_link, attrs) do
    magic_link
    |> cast(attrs, [:token_hash, :email, :expires_at])
    |> validate_required([:token_hash, :email, :expires_at])
    |> unique_constraint(:token_hash)
  end

  def generate_token, do: :crypto.strong_rand_bytes(@token_length) |> Base.url_encode64(padding: false)

  def hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  def expires_at do
    DateTime.utc_now()
    |> DateTime.add(@ttl_minutes * 60, :second)
    |> DateTime.truncate(:second)
  end

  def valid?(%__MODULE__{expires_at: exp, used_at: nil}) do
    DateTime.compare(DateTime.utc_now(), exp) == :lt
  end
  def valid?(_), do: false
end
