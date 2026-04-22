defmodule KomunBackend.Channels.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @visibilities ~w(public role_restricted invite_only)

  schema "building_channels" do
    field :name, :string
    field :description, :string
    field :visibility, :string, default: "public"
    field :is_readonly, :boolean, default: false

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :created_by, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :description, :visibility, :is_readonly, :building_id, :created_by_id])
    |> validate_required([:name, :building_id])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:description, max: 280)
    |> validate_inclusion(:visibility, @visibilities)
    |> unique_constraint([:building_id, :name], message: "Un canal avec ce nom existe déjà.")
  end

  def visibilities, do: @visibilities
end
