defmodule KomunBackend.Incidents.IncidentComment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "incident_comments" do
    field :body, :string
    field :photo_urls, {:array, :string}, default: []
    field :is_internal, :boolean, default: false

    belongs_to :incident, KomunBackend.Incidents.Incident
    belongs_to :author, KomunBackend.Accounts.User, foreign_key: :author_id

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :photo_urls, :is_internal, :incident_id, :author_id])
    |> validate_required([:body, :incident_id, :author_id])
    |> validate_length(:body, min: 1, max: 2000)
  end
end
