defmodule KomunBackend.ImprovementTickets do
  @moduledoc """
  Tickets de feedback produit. Voir
  `KomunBackend.ImprovementTickets.ImprovementTicket` pour le schéma.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.ImprovementTickets.ImprovementTicket

  @doc """
  Liste les tickets de l'auteur (vue utilisateur dans /ameliorations).
  Tri descendant : le plus récent en premier.
  """
  def list_by_author(author_id, filters \\ %{}) do
    base =
      from(t in ImprovementTicket,
        where: t.author_id == ^author_id,
        preload: [:author],
        order_by: [desc: t.inserted_at]
      )

    base
    |> apply_filter(:status, filters["status"])
    |> apply_filter(:kind, filters["kind"])
    |> Repo.all()
  end

  @doc """
  Liste l'ensemble des tickets pour la console admin. Préchargement
  de l'auteur pour pouvoir afficher qui a écrit le ticket dans la
  liste sans n+1.
  """
  def list_all(filters \\ %{}) do
    base =
      from(t in ImprovementTicket,
        preload: [:author, :building],
        order_by: [desc: t.inserted_at]
      )

    base
    |> apply_filter(:status, filters["status"])
    |> apply_filter(:kind, filters["kind"])
    |> Repo.all()
  end

  defp apply_filter(q, _field, nil), do: q
  defp apply_filter(q, _field, ""), do: q
  defp apply_filter(q, :status, v), do: where(q, [t], t.status == ^v)
  defp apply_filter(q, :kind, v), do: where(q, [t], t.kind == ^v)

  def get_ticket!(id),
    do: Repo.get!(ImprovementTicket, id) |> Repo.preload([:author, :building])

  def get_ticket(id),
    do: Repo.get(ImprovementTicket, id)

  @doc """
  Crée un ticket pour l'utilisateur courant. Le `author_id` est forcé
  depuis le contexte d'appel — le client ne peut pas usurper un autre
  auteur via le payload.
  """
  def create_ticket(author_id, attrs, building_id \\ nil) do
    attrs =
      attrs
      |> Map.merge(%{"author_id" => author_id})
      |> maybe_put("building_id", building_id)

    %ImprovementTicket{}
    |> ImprovementTicket.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, ticket} -> {:ok, Repo.preload(ticket, [:author, :building])}
      err -> err
    end
  end

  @doc """
  Mise à jour admin : statut + note. Voir `admin_changeset/2` pour la
  liste exacte des champs autorisés.
  """
  def admin_update(%ImprovementTicket{} = ticket, attrs) do
    ticket
    |> ImprovementTicket.admin_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, t} -> {:ok, Repo.preload(t, [:author, :building])}
      err -> err
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Ajoute une URL de capture d'écran au ticket. On garde la liste à
  plat — pas de métadonnées par capture (filename, taille, mime) car
  l'usage est purement illustratif.
  """
  def append_screenshot(%ImprovementTicket{} = ticket, url) when is_binary(url) do
    new_urls = (ticket.screenshot_urls || []) ++ [url]

    ticket
    |> ImprovementTicket.screenshots_changeset(new_urls)
    |> Repo.update()
    |> case do
      {:ok, t} -> {:ok, Repo.preload(t, [:author, :building])}
      err -> err
    end
  end

  @doc """
  Retire une URL de la liste. No-op si l'URL n'est pas dans le tableau —
  on ne crash pas pour ça (le client a peut-être supprimé la même
  capture deux fois en double-tap).
  """
  def remove_screenshot(%ImprovementTicket{} = ticket, url) when is_binary(url) do
    new_urls = Enum.reject(ticket.screenshot_urls || [], &(&1 == url))

    ticket
    |> ImprovementTicket.screenshots_changeset(new_urls)
    |> Repo.update()
    |> case do
      {:ok, t} -> {:ok, Repo.preload(t, [:author, :building])}
      err -> err
    end
  end
end
