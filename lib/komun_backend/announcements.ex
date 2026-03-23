defmodule KomunBackend.Announcements do
  @moduledoc "Announcements context."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Announcements.Announcement
  alias KomunBackend.Notifications

  def list_announcements(building_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(a in Announcement,
      where: a.building_id == ^building_id and a.is_published == true,
      order_by: [desc: a.is_pinned, desc: a.inserted_at],
      limit: ^limit,
      preload: [:author]
    )
    |> Repo.all()
  end

  def get_announcement!(id), do: Repo.get!(Announcement, id) |> Repo.preload(:author)

  def create_announcement(building_id, author_id, attrs) do
    with {:ok, announcement} <-
           %Announcement{}
           |> Announcement.changeset(Map.merge(attrs, %{building_id: building_id, author_id: author_id}))
           |> Repo.insert() do
      if announcement.is_published do
        Notifications.send_to_building(
          building_id,
          "Nouvelle annonce",
          announcement.title,
          %{type: "announcement", announcement_id: announcement.id, building_id: building_id}
        )
      end

      {:ok, announcement}
    end
  end

  def mark_read(announcement_id, user_id) do
    ann = Repo.get!(Announcement, announcement_id)
    ann
    |> Announcement.mark_read_changeset(user_id)
    |> Repo.update()
  end
end
