defmodule KomunBackend.Repo.Migrations.CreateContacts do
  use Ecto.Migration

  @moduledoc """
  Annuaire de contacts par résidence — personnes physiques (avocat,
  architecte, contact mairie…) ou personnes morales (syndic alternatif,
  cabinet d'expertise…) que les membres veulent garder sous la main pour
  rédiger des courriers ou simplement avoir leurs coordonnées.

  Lecture : tous les membres de la résidence.
  Écriture : conseil syndical + syndic + super_admin.
  """

  def change do
    create table(:contacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, null: false
      add :kind, :string, null: false, default: "legal_entity"
      add :title, :string
      add :email, :string
      add :phone, :string
      add :address, :text
      add :notes, :text

      add :residence_id,
          references(:residences, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:contacts, [:residence_id])
    create index(:contacts, [:residence_id, :name])
  end
end
