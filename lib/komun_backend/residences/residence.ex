defmodule KomunBackend.Residences.Residence do
  @moduledoc """
  Une **résidence** regroupe un ou plusieurs bâtiments d'une même copropriété.

  C'est l'unité naturelle d'invitation : un président de CS partage le
  `join_code` de sa résidence aux voisins, qui choisissent ensuite leur
  bâtiment à l'inscription. Les bâtiments gardent un `join_code` distinct
  pour les cas où on veut envoyer quelqu'un directement dans un immeuble
  précis (invitation ciblée, affiche dans un hall particulier).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "residences" do
    field :name, :string
    field :slug, :string
    field :address, :string
    field :city, :string
    field :postal_code, :string
    field :country, :string, default: "FR"
    field :cover_url, :string
    field :join_code, :string
    field :settings, :map, default: %{}
    field :is_active, :boolean, default: true

    belongs_to :organization, KomunBackend.Organizations.Organization
    has_many :buildings, KomunBackend.Buildings.Building

    timestamps(type: :utc_datetime)
  end

  def changeset(residence, attrs) do
    residence
    |> cast(attrs, [
      :name,
      :slug,
      :address,
      :city,
      :postal_code,
      :country,
      :cover_url,
      :join_code,
      :settings,
      :is_active,
      :organization_id
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 160)
    |> put_slug()
    |> unique_constraint(:join_code)
  end

  defp put_slug(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        slug =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        put_change(changeset, :slug, slug)
    end
  end
end
