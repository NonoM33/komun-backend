defmodule KomunBackend.Announcements.Announcement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "announcements" do
    field :title, :string
    field :body, :string
    field :category, Ecto.Enum,
      values: [:info, :travaux, :urgent, :ag, :reglementation, :autre, :community, :event],
      default: :info
    field :is_pinned, :boolean, default: false
    field :is_published, :boolean, default: true
    field :publish_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :attachment_urls, {:array, :string}, default: []
    field :read_by_user_ids, {:array, :binary_id}, default: []

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :author, KomunBackend.Accounts.User, foreign_key: :author_id

    timestamps(type: :utc_datetime)
  end

  def changeset(ann, attrs) do
    ann
    |> cast(attrs, [:title, :body, :category, :is_pinned, :is_published,
                    :publish_at, :expires_at, :attachment_urls,
                    :building_id, :author_id])
    |> validate_required([:title, :body, :building_id, :author_id])
    |> validate_length(:title, max: 200)
  end

  def mark_read_changeset(ann, user_id) do
    ids = (ann.read_by_user_ids || []) |> Enum.reject(&(&1 == user_id))
    ann |> Ecto.Changeset.change(read_by_user_ids: [user_id | ids])
  end
end
