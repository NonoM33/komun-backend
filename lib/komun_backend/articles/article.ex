defmodule KomunBackend.Articles.Article do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:draft, :review, :published, :archived]
  @categories [:actualite, :guide, :vie_copro, :travaux, :evenement, :autre]

  schema "articles" do
    field :title, :string
    field :excerpt, :string
    field :content, :string, default: ""
    field :category, Ecto.Enum, values: @categories, default: :actualite
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :is_pinned, :boolean, default: false
    field :cover_url, :string
    field :reviewer_note, :string
    field :published_at, :utc_datetime

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :author, KomunBackend.Accounts.User, foreign_key: :author_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def categories, do: @categories

  @doc """
  Changeset pour la création / l'édition de contenu. Volontairement
  ne touche **pas** au `:status` : les transitions passent par
  `transition_changeset/2` pour qu'on puisse y poser plus tard la
  logique de notif / d'audit sans risquer un changement silencieux.
  """
  def changeset(article, attrs) do
    article
    |> cast(attrs, [
      :title,
      :excerpt,
      :content,
      :category,
      :is_pinned,
      :cover_url,
      :building_id,
      :author_id
    ])
    |> validate_required([:title, :building_id])
    |> validate_length(:title, max: 200)
  end

  @doc """
  Changeset dédié aux transitions de statut (brouillon → relecture →
  publié → archivé). Pose `published_at` la première fois qu'on passe
  en `published` ; ne le réinitialise pas ensuite.
  """
  def transition_changeset(article, attrs) do
    article
    |> cast(attrs, [:status, :reviewer_note])
    |> validate_required([:status])
    |> maybe_set_published_at()
  end

  defp maybe_set_published_at(changeset) do
    case get_change(changeset, :status) do
      :published ->
        if is_nil(get_field(changeset, :published_at)) do
          put_change(
            changeset,
            :published_at,
            DateTime.utc_now() |> DateTime.truncate(:second)
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
