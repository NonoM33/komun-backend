defmodule KomunBackend.Assistant.Conversation do
  @moduledoc """
  Multi-turn chat thread between a resident and the assistant. Groups
  `AssistantMessage` rows so the frontend can list / switch / delete
  threads like ChatGPT.

  Scope: one building × one user × N conversations. The title starts as
  "Nouvelle conversation" and is replaced by a trimmed version of the
  first question so the sidebar shows something meaningful.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "assistant_conversations" do
    field :title, :string, default: "Nouvelle conversation"
    field :last_message_at, :utc_datetime
    field :message_count, :integer, default: 0

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :user, KomunBackend.Accounts.User

    has_many :messages, KomunBackend.Assistant.AssistantMessage,
      foreign_key: :conversation_id,
      preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  def changeset(conv, attrs) do
    conv
    |> cast(attrs, [:title, :last_message_at, :message_count, :building_id, :user_id])
    |> validate_required([:building_id, :user_id])
    |> validate_length(:title, max: 120)
  end
end
