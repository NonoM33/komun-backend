defmodule KomunBackend.Contacts.Contact do
  @moduledoc """
  Une entrée de l'annuaire d'une résidence : un destinataire que le
  conseil / le syndic veut garder sous la main pour rédiger des courriers
  (cabinet de syndic alternatif, avocat, architecte, contact mairie…)
  ou simplement disposer des coordonnées.

  Toujours rattaché à une résidence (jamais à un bâtiment précis — un
  cabinet d'avocat sert toute la copropriété).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "contacts" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:person, :legal_entity], default: :legal_entity
    field :title, :string
    field :email, :string
    field :phone, :string
    field :address, :string
    field :notes, :string

    belongs_to :residence, KomunBackend.Residences.Residence
    belongs_to :created_by, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @castable [:name, :kind, :title, :email, :phone, :address, :notes]

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, @castable)
    # Nilify avant validate_format — sinon une chaîne vide remonte une
    # erreur "email invalide" au lieu d'être traitée comme absente.
    |> nilify_blank([:title, :email, :phone, :address, :notes])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:title, max: 200)
    |> validate_length(:email, max: 200)
    |> validate_length(:phone, max: 60)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "doit être une adresse email valide"
    )
  end

  defp nilify_blank(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, cs ->
      case get_change(cs, field) do
        nil -> cs
        v when is_binary(v) -> if String.trim(v) == "", do: put_change(cs, field, nil), else: cs
        _ -> cs
      end
    end)
  end
end
