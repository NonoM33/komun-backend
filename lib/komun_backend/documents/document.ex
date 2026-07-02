defmodule KomunBackend.Documents.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Mandatory categories the frontend surfaces as "missing" banners when
  # absent. Keep in sync with Documents.mandatory_categories/0.
  @mandatory_categories [:reglement]

  schema "documents" do
    field :title, :string
    field :filename, :string
    field :file_url, :string

    field :category, Ecto.Enum,
      values: [
        :reglement,
        :pv_ag,
        :pv_conseil,
        :contrat,
        :facture,
        :devis,
        :assurance,
        :charges,
        :plans,
        :autre
      ],
      default: :autre

    field :file_size_bytes, :integer
    field :mime_type, :string
    field :is_public, :boolean, default: true
    field :is_pinned, :boolean, default: false
    field :is_archived, :boolean, default: false
    field :archived_at, :utc_datetime
    field :content_text, :string

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :uploaded_by, KomunBackend.Accounts.User, foreign_key: :uploaded_by_id

    timestamps(type: :utc_datetime)
  end

  def changeset(doc, attrs) do
    doc
    |> cast(attrs, [
      :title,
      :filename,
      :file_url,
      :category,
      :file_size_bytes,
      :mime_type,
      :is_public,
      :is_pinned,
      :is_archived,
      :archived_at,
      :content_text,
      :building_id,
      :uploaded_by_id
    ])
    |> validate_required([:title, :building_id])
    |> maybe_auto_pin_reglement()
  end

  def mandatory_categories, do: @mandatory_categories

  # Règlement is always pinned by default — the syndic may un-pin manually
  # afterwards, but a fresh upload lands on top of the list.
  defp maybe_auto_pin_reglement(changeset) do
    case get_change(changeset, :category) do
      :reglement ->
        if is_pinned_provided?(changeset) do
          changeset
        else
          put_change(changeset, :is_pinned, true)
        end

      _ ->
        changeset
    end
  end

  # `get_change/2` renvoie `nil` quand la valeur castée est égale au défaut
  # du schéma (`is_pinned` par défaut à `false`) — on ne peut donc PAS s'en
  # servir pour distinguer « champ absent » de « champ explicitement à
  # `false` ». On regarde les params bruts du changeset : si l'appelant a
  # fourni `is_pinned` (string ou atom), on respecte son choix.
  defp is_pinned_provided?(%{params: params}) when is_map(params) do
    Map.has_key?(params, "is_pinned") or Map.has_key?(params, :is_pinned)
  end

  defp is_pinned_provided?(_changeset), do: false
end
