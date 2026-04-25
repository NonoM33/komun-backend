defmodule KomunBackend.Battles.Battle do
  @moduledoc """
  Tournoi à élimination — N options au round 1, on garde le top-2 (ou
  les ex-aequo) pour le round 2 (run-off), le gagnant est le top-1 du
  dernier round.

  La cadence est pilotée par un job Oban (`Battles.AdvanceJob`) qui se
  réveille à `current_vote.ends_at`, fait le tally et soit clôture la
  battle, soit ouvre le round suivant.

  Les VoteOption du round courant sont la source de vérité pour ce qui
  reste en lice. Quand on passe au round 2, on crée un nouveau Vote +
  de nouvelles VoteOption (label/image copiés depuis le round 1) — ça
  permet aux résidents de re-voter sans contamination du score précédent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias KomunBackend.Votes.Vote

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:running, :finished, :cancelled]

  schema "battles" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :running

    field :round_duration_days, :integer, default: 3
    field :max_rounds, :integer, default: 2
    field :current_round, :integer, default: 1
    field :quorum_pct, :integer, default: 30

    field :winning_option_label, :string

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :created_by, KomunBackend.Accounts.User

    has_many :votes, Vote, preload_order: [asc: :round_number]

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def create_changeset(battle, attrs) do
    battle
    |> cast(attrs, [
      :title,
      :description,
      :round_duration_days,
      :max_rounds,
      :quorum_pct,
      :building_id,
      :created_by_id
    ])
    |> validate_required([:title, :building_id, :created_by_id])
    |> validate_length(:title, min: 3, max: 200)
    |> validate_number(:round_duration_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 30)
    |> validate_number(:max_rounds, greater_than_or_equal_to: 1, less_than_or_equal_to: 4)
    |> validate_number(:quorum_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end

  def update_changeset(battle, attrs) do
    battle
    |> cast(attrs, [:title, :description, :status, :winning_option_label, :current_round])
    |> validate_length(:title, min: 3, max: 200)
  end
end
