defmodule KomunBackend.Doleances.DoleanceSupport do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "doleance_supports" do
    field :comment, :string
    field :photo_urls, {:array, :string}, default: []

    belongs_to :doleance, KomunBackend.Doleances.Doleance
    belongs_to :user, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(support, attrs) do
    support
    |> cast(attrs, [:comment, :photo_urls, :doleance_id, :user_id])
    |> validate_required([:doleance_id, :user_id])
    |> unique_constraint([:doleance_id, :user_id])
  end
end
