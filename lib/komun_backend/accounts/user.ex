defmodule KomunBackend.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :role, Ecto.Enum,
      values: [:super_admin, :syndic_manager, :syndic_staff, :president_cs,
               :membre_cs, :coproprietaire, :locataire, :gardien, :prestataire],
      default: :coproprietaire

    field :first_name, :string
    field :last_name, :string
    field :phone, :string
    field :avatar_url, :string
    field :locale, :string, default: "fr"
    field :push_tokens, {:array, :string}, default: []
    field :last_sign_in_at, :utc_datetime

    belongs_to :organization, KomunBackend.Organizations.Organization

    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :role, :first_name, :last_name, :phone, :avatar_url,
                    :locale, :push_tokens, :organization_id])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
    |> validate_inclusion(:role, ~w(super_admin syndic_manager syndic_staff president_cs
                                    membre_cs coproprietaire locataire gardien prestataire)a)
  end

  def display_name(%__MODULE__{first_name: nil, email: email}), do: email
  def display_name(%__MODULE__{first_name: f, last_name: nil}), do: f
  def display_name(%__MODULE__{first_name: f, last_name: l}), do: "#{f} #{l}"
end
