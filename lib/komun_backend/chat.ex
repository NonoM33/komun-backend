defmodule KomunBackend.Chat do
  @moduledoc "Chat context — messages persistés par room (building)."

  import Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.Chat.Message

  @default_limit 50

  def list_messages(room_id, limit \\ @default_limit) do
    from(m in Message,
      where: m.room_id == ^room_id,
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: :author
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  def create_message(room_id, author_id, body) do
    %Message{}
    |> Message.changeset(%{room_id: room_id, author_id: author_id, body: body})
    |> Repo.insert()
  end
end
