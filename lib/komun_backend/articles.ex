defmodule KomunBackend.Articles do
  @moduledoc """
  Articles éditoriaux pour la copropriété (actualité, guide, vie de
  copro, …). Cycle de vie : brouillon → relecture → publié → archivé.

  Les voisins lambda ne voient que le contenu publié ; les rôles
  privilégiés (CS + syndic + super_admin) voient toute la pile.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Articles.Article

  # Rôles autorisés à créer / éditer / publier un article. Aligné sur
  # `Documents.uploader_roles/0` pour rester cohérent côté frontend.
  @editor_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  def editor_roles, do: @editor_roles

  @doc """
  Liste des articles d'un bâtiment. Par défaut, n'affiche que les
  articles publiés (vue voisin). Passer `:all` ou un statut précis
  pour la vue éditeur.
  """
  def list_articles(building_id, opts \\ []) do
    status = Keyword.get(opts, :status, :published)

    base =
      from(a in Article,
        where: a.building_id == ^building_id,
        order_by: [
          desc: a.is_pinned,
          desc: coalesce(a.published_at, a.inserted_at)
        ],
        preload: [:author]
      )

    query =
      case status do
        :all -> base
        s when s in [:draft, :review, :published, :archived] -> where(base, [a], a.status == ^s)
        _ -> where(base, [a], a.status == :published)
      end

    Repo.all(query)
  end

  def get_article!(id), do: Repo.get!(Article, id) |> Repo.preload(:author)

  def create_article(building_id, author_id, attrs) do
    %Article{}
    |> Article.changeset(
      Map.merge(attrs, %{building_id: building_id, author_id: author_id})
    )
    |> Repo.insert()
  end

  def update_article(%Article{} = article, attrs) do
    article
    |> Article.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Transition de statut. Pose `published_at` automatiquement la
  première fois qu'on passe en `:published`. Hook futur pour
  notification voisins / audit log.
  """
  def transition(%Article{} = article, status, reviewer_note \\ nil) do
    article
    |> Article.transition_changeset(%{status: status, reviewer_note: reviewer_note})
    |> Repo.update()
  end

  def delete_article(%Article{} = article), do: Repo.delete(article)
end
