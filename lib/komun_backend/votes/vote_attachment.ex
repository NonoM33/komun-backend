defmodule KomunBackend.Votes.VoteAttachment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(photo document)

  schema "vote_attachments" do
    field :kind, :string
    field :file_url, :string
    field :filename, :string
    field :mime_type, :string
    field :file_size_bytes, :integer
    field :position, :integer, default: 0

    belongs_to :vote, KomunBackend.Votes.Vote

    timestamps(type: :utc_datetime)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:kind, :file_url, :filename, :mime_type, :file_size_bytes, :position])
    |> validate_required([:kind, :file_url])
    |> validate_inclusion(:kind, @kinds)
  end
end
