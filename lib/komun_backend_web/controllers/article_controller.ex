defmodule KomunBackendWeb.ArticleController do
  @moduledoc """
  Articles éditoriaux pour la copro. Création / édition réservées au
  CS et au syndic ; consultation publique des articles `:published`
  pour tout membre du bâtiment.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.{Articles, Buildings}
  alias KomunBackend.Auth.Guardian

  defp serialize(a) do
    %{
      id: a.id,
      title: a.title,
      excerpt: a.excerpt,
      content: a.content,
      category: a.category,
      status: a.status,
      is_pinned: a.is_pinned,
      cover_url: a.cover_url,
      reviewer_note: a.reviewer_note,
      published_at: a.published_at,
      building_id: a.building_id,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at,
      author:
        if(a.author,
          do: %{
            id: a.author.id,
            email: a.author.email,
            first_name: a.author.first_name,
            last_name: a.author.last_name,
            avatar_url: a.author.avatar_url
          },
          else: nil
        )
    }
  end

  def index(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_member(conn, building_id, user) do
      status_param = Map.get(params, "status")

      requested_status =
        case status_param do
          nil -> nil
          "all" -> :all
          s when is_binary(s) ->
            try do
              String.to_existing_atom(s)
            rescue
              _ -> :unknown
            end

          _ ->
            :unknown
        end

      # Les voisins lambda ne voient que les articles publiés ; un
      # éditeur peut interroger `status=all` ou un statut précis.
      can_edit = editor?(building_id, user)

      effective_status =
        cond do
          can_edit and requested_status in [:all, :draft, :review, :published, :archived] ->
            requested_status

          true ->
            :published
        end

      articles = Articles.list_articles(building_id, status: effective_status)
      json(conn, %{data: Enum.map(articles, &serialize/1)})
    end
  end

  def show(conn, %{"id" => id, "building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    article = Articles.get_article!(id)

    with :ok <- authorize_member(conn, building_id, user) do
      cond do
        article.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Article introuvable"}) |> halt()

        article.status != :published and not editor?(building_id, user) ->
          conn |> put_status(:not_found) |> json(%{error: "Article introuvable"}) |> halt()

        true ->
          json(conn, %{data: serialize(article)})
      end
    end
  end

  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_editor(conn, building_id, user) do
      attrs = take_string_keys(params, ~w(title excerpt content category is_pinned cover_url))

      case Articles.create_article(building_id, user.id, attrs) do
        {:ok, article} ->
          article = KomunBackend.Repo.preload(article, :author)
          conn |> put_status(:created) |> json(%{data: serialize(article)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: format_errors(changeset)})
      end
    end
  end

  def update(conn, %{"id" => id, "building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    article = Articles.get_article!(id)

    with :ok <- authorize_editor(conn, building_id, user),
         :ok <- ensure_same_building(conn, article, building_id) do
      attrs = take_string_keys(params, ~w(title excerpt content category is_pinned cover_url))

      case Articles.update_article(article, attrs) do
        {:ok, updated} ->
          updated = KomunBackend.Repo.preload(updated, :author)
          json(conn, %{data: serialize(updated)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: format_errors(changeset)})
      end
    end
  end

  def delete(conn, %{"id" => id, "building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    article = Articles.get_article!(id)

    with :ok <- authorize_editor(conn, building_id, user),
         :ok <- ensure_same_building(conn, article, building_id) do
      {:ok, _} = Articles.delete_article(article)
      send_resp(conn, :no_content, "")
    end
  end

  # POST /api/v1/buildings/:building_id/articles/:id/transition
  def transition(conn, %{"id" => id, "building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    article = Articles.get_article!(id)

    with :ok <- authorize_editor(conn, building_id, user),
         :ok <- ensure_same_building(conn, article, building_id),
         {:ok, status} <- parse_status(Map.get(params, "status")) do
      reviewer_note = Map.get(params, "reviewer_note")

      case Articles.transition(article, status, reviewer_note) do
        {:ok, updated} ->
          updated = KomunBackend.Repo.preload(updated, :author)
          json(conn, %{data: serialize(updated)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: format_errors(changeset)})
      end
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Statut invalide"})
        |> halt()

      other ->
        other
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp parse_status(s) when s in ["draft", "review", "published", "archived"],
    do: {:ok, String.to_existing_atom(s)}

  defp parse_status(s) when s in [:draft, :review, :published, :archived],
    do: {:ok, s}

  defp parse_status(_), do: :error

  defp authorize_member(conn, building_id, user) do
    cond do
      user.role == :super_admin -> :ok
      Buildings.member?(building_id, user.id) -> :ok
      true -> conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp authorize_editor(conn, building_id, user) do
    if editor?(building_id, user) do
      :ok
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Seuls le syndic et le conseil syndical peuvent gérer les articles."})
      |> halt()
    end
  end

  defp editor?(building_id, user) do
    member_role = Buildings.get_member_role(building_id, user.id)

    user.role == :super_admin or
      user.role in Articles.editor_roles() or
      member_role in Articles.editor_roles()
  end

  defp ensure_same_building(conn, article, building_id) do
    if article.building_id == building_id do
      :ok
    else
      conn |> put_status(:not_found) |> json(%{error: "Article introuvable"}) |> halt()
    end
  end

  defp take_string_keys(params, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(params, key) do
        {:ok, value} -> Map.put(acc, String.to_existing_atom(key), value)
        :error -> acc
      end
    end)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
  end
end
