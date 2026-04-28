defmodule KomunBackend.Incidents.IncidentFile do
  @moduledoc """
  Pièce jointe attachée à un incident (photo de la fuite, devis du
  prestataire, …). Schéma volontairement aligné sur `DiligenceFile`
  pour partager la même stratégie de stockage et la même logique
  d'upload côté controller.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:photo, :document]

  schema "incident_files" do
    field :kind, Ecto.Enum, values: @kinds
    field :filename, :string
    field :file_url, :string
    field :file_size_bytes, :integer
    field :mime_type, :string

    belongs_to :incident, KomunBackend.Incidents.Incident
    belongs_to :uploaded_by, KomunBackend.Accounts.User, foreign_key: :uploaded_by_id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(file, attrs) do
    file
    |> cast(attrs, [
      :incident_id,
      :uploaded_by_id,
      :kind,
      :filename,
      :file_url,
      :file_size_bytes,
      :mime_type
    ])
    |> validate_required([:incident_id, :kind, :filename, :file_url])
    |> validate_length(:filename, max: 255)
    |> assoc_constraint(:incident)
  end
end
