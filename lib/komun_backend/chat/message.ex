defmodule KomunBackend.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :body, :string
    field :room_id, :string

    belongs_to :author, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :room_id, :author_id])
    |> validate_required([:body, :room_id, :author_id])
    |> validate_length(:body, min: 1, max: 4000)
  end
end
