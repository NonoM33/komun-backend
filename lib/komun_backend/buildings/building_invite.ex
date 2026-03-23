defmodule KomunBackend.Buildings.BuildingInvite do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_roles ~w(president_cs membre_cs coproprietaire locataire gardien prestataire)

  schema "building_invites" do
    field :token, :string
    field :role, :string, default: "coproprietaire"
    field :is_active, :boolean, default: true
    field :used_count, :integer, default: 0
    field :max_uses, :integer
    field :expires_at, :utc_datetime

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :created_by, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:token, :role, :is_active, :used_count, :max_uses, :expires_at, :building_id, :created_by_id])
    |> validate_required([:token, :building_id])
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint(:token)
  end
end
