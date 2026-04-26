defmodule KomunBackend.Accounts.MagicLink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @token_length 32
  @ttl_minutes 15
  @code_length 6
  # 5 essais maxi sur le code 6 chiffres avant invalidation. À 5 essais
  # sur 1 000 000 de combinaisons, la probabilité de brute-force avant
  # expiration TTL reste astronomiquement faible.
  @max_code_attempts 5

  schema "magic_links" do
    field :token_hash, :string
    # Code à 6 chiffres haché (sha256). Sert au flow "tape le code"
    # utilisé sur iOS standalone, puisqu'un clic dans Mail ouvre Safari
    # et pose les tokens dans le mauvais contexte localStorage.
    field :code_hash, :string
    field :attempts_count, :integer, default: 0
    field :email, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    # Optional signup payload carried through the magic link so the user
    # lands already named and joined to a residence.
    field :join_code, :string
    field :first_name, :string
    field :last_name, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(magic_link, attrs) do
    magic_link
    |> cast(attrs, [
      :token_hash,
      :code_hash,
      :email,
      :expires_at,
      :join_code,
      :first_name,
      :last_name
    ])
    |> validate_required([:token_hash, :code_hash, :email, :expires_at])
    |> validate_length(:first_name, max: 80)
    |> validate_length(:last_name, max: 80)
    |> unique_constraint(:token_hash)
  end

  def generate_token, do: :crypto.strong_rand_bytes(@token_length) |> Base.url_encode64(padding: false)

  def hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc """
  Code à 6 chiffres aléatoire (uniforme sur 000000–999999), formaté
  avec un padding zéro à gauche pour que l'utilisateur ait toujours
  6 caractères à recopier.
  """
  def generate_code do
    :crypto.strong_rand_bytes(4)
    |> :binary.decode_unsigned()
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(@code_length, "0")
  end

  def hash_code(code), do: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)

  def max_code_attempts, do: @max_code_attempts

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
