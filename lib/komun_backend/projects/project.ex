defmodule KomunBackend.Projects.Project do
  @moduledoc """
  Copro project — groups devis (quotes) around a concrete need (ravalement,
  toiture, ascenseur…) so the conseil can collect, compare and put the chosen
  one to a vote.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:collecting, :voting, :chosen, :done]

  schema "projects" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :collecting
    field :chosen_devis_id, :binary_id

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :created_by, KomunBackend.Accounts.User
    belongs_to :vote, KomunBackend.Votes.Vote
    has_many :devis, KomunBackend.Projects.Devis, preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :chosen_devis_id,
      :vote_id,
      :building_id,
      :created_by_id
    ])
    |> validate_required([:title, :building_id])
    |> validate_length(:title, min: 3, max: 200)
  end
end
