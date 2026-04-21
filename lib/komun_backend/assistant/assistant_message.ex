defmodule KomunBackend.Assistant.AssistantMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "assistant_messages" do
    field :question, :string
    field :answer, :string
    field :model, :string
    field :tokens_prompt, :integer
    field :tokens_completion, :integer
    field :status, :string, default: "ok"
    field :error, :string

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :user, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, [
      :question,
      :answer,
      :model,
      :tokens_prompt,
      :tokens_completion,
      :status,
      :error,
      :building_id,
      :user_id
    ])
    |> validate_required([:question, :building_id, :user_id])
    |> validate_length(:question, min: 3, max: 2000)
  end
end
