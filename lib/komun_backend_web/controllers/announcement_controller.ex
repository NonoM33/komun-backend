defmodule KomunBackendWeb.AnnouncementController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Announcements

  defp serialize(a) do
    %{
      id: a.id,
      title: a.title,
      body: a.body,
      category: a.category,
      is_pinned: a.is_pinned,
      attachment_urls: a.attachment_urls || [],
      inserted_at: a.inserted_at,
      author: if(a.author, do: %{
        id: a.author.id,
        email: a.author.email,
        first_name: a.author.first_name,
        last_name: a.author.last_name,
        avatar_url: a.author.avatar_url
      }, else: nil)
    }
  end

  def index(conn, %{"building_id" => building_id}) do
    announcements = Announcements.list_announcements(building_id)
    json(conn, %{data: Enum.map(announcements, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    announcement = Announcements.get_announcement!(id)
    json(conn, %{data: serialize(announcement)})
  end

  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = %{
      title: params["title"],
      body: params["body"],
      category: params["category"] || "info",
      is_pinned: params["is_pinned"] || false
    }
    case Announcements.create_announcement(building_id, user.id, attrs) do
      {:ok, ann} ->
        ann = KomunBackend.Repo.preload(ann, :author)
        conn |> put_status(:created) |> json(%{data: serialize(ann)})
      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def update(conn, _params), do: json(conn, %{data: %{}})
  def delete(conn, _params), do: send_resp(conn, :no_content, "")

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
