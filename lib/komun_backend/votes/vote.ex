defmodule KomunBackend.Votes.Vote do
  use Ecto.Schema
  import Ecto.Changeset

  alias KomunBackend.Votes.{VoteOption, VoteAttachment}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @vote_types ~w(binary single_choice)

  schema "votes" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:open, :closed], default: :open
    field :ends_at, :utc_datetime
    field :is_anonymous, :boolean, default: false
    field :vote_type, :string, default: "binary"

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :created_by, KomunBackend.Accounts.User
    belongs_to :project, KomunBackend.Projects.Project

    has_many :responses, KomunBackend.Votes.VoteResponse
    has_many :options, VoteOption, on_replace: :delete
    has_many :attachments, VoteAttachment, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @cast_fields [
    :title,
    :description,
    :status,
    :ends_at,
    :is_anonymous,
    :vote_type,
    :building_id,
    :created_by_id,
    :project_id
  ]

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, @cast_fields)
    |> cast_assoc(:options, with: &VoteOption.changeset/2)
    |> cast_assoc(:attachments, with: &VoteAttachment.changeset/2)
    |> validate_required([:title, :building_id, :created_by_id])
    |> validate_length(:title, min: 3, max: 200)
    |> validate_inclusion(:vote_type, @vote_types)
    |> validate_options_for_type()
  end

  # single_choice votes need at least 2 options. binary votes ignore options.
  defp validate_options_for_type(changeset) do
    case get_field(changeset, :vote_type) do
      "single_choice" ->
        case get_field(changeset, :options) do
          opts when is_list(opts) and length(opts) >= 2 ->
            changeset

          _ ->
            add_error(
              changeset,
              :options,
              "single_choice vote needs at least 2 options"
            )
        end

      _ ->
        changeset
    end
  end
end
