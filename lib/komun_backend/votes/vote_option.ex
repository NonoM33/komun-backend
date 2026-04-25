defmodule KomunBackend.Votes.VoteOption do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vote_options" do
    field :label, :string
    field :position, :integer, default: 0
    field :is_recommended, :boolean, default: false

    field :attachment_url, :string
    field :attachment_filename, :string
    field :attachment_mime_type, :string
    field :attachment_size_bytes, :integer

    belongs_to :vote, KomunBackend.Votes.Vote
    belongs_to :devis, KomunBackend.Projects.Devis

    timestamps(type: :utc_datetime)
  end

  @cast_fields [
    :label,
    :position,
    :is_recommended,
    :devis_id,
    :attachment_url,
    :attachment_filename,
    :attachment_mime_type,
    :attachment_size_bytes
  ]

  def changeset(option, attrs) do
    option
    |> cast(attrs, @cast_fields)
    |> validate_required([:label])
    |> validate_length(:label, min: 1, max: 200)
  end
end
