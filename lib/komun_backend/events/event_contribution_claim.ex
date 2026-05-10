defmodule KomunBackend.Events.EventContributionClaim do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "event_contribution_claims" do
    field :quantity, :integer, default: 1
    field :comment, :string

    belongs_to :contribution, KomunBackend.Events.EventContribution
    belongs_to :user, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:contribution_id, :user_id, :quantity, :comment])
    |> validate_required([:contribution_id, :user_id])
    |> validate_number(:quantity, greater_than: 0, less_than_or_equal_to: 999)
    |> validate_length(:comment, max: 280)
  end
end
