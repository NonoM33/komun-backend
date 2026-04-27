defmodule KomunBackendWeb.WrittenDocumentController do
  @moduledoc """
  Documents rédigés en ligne (PV de conseil, comptes-rendus, …).
  Mêmes règles d'accès que les articles : édition réservée au CS et
  au syndic, lecture publique des `:published` pour tout membre du
  bâtiment.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, WrittenDocuments}
  alias KomunBackend.Auth.Guardian

  defp serialize(d) do
    %{
      id: d.id,
      title: d.title,
      content: d.content,
      category: d.category,
      status: d.status,
      is_pinned: d.is_pinned,
      is_archived: d.is_archived,
      archived_at: d.archived_at,
      reviewer_note: d.reviewer_note,
      published_at: d.published_at,
      building_id: d.building_id,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at,
      author:
        if(d.author,
          do: %{
            id: d.author.id,
            email: d.author.email,
            first_name: d.author.first_name,
            last_name: d.author.last_name,
            avatar_url: d.author.avatar_url
          },
          else: nil
        )
    }
  end

  def index(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_member(conn, building_id, user) do
      can_edit = editor?(building_id, user)

      requested_status =
        case Map.get(params, "status") do
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

      effective_status =
        cond do
          can_edit and requested_status in [:all, :draft, :review, :published, :archived] ->
            requested_status

          true ->
            :published
        end

      archived = truthy(Map.get(params, "archived")) and can_edit

      docs = WrittenDocuments.list_written_documents(building_id, status: effective_status, archived: archived)
      json(conn, %{data: Enum.map(docs, &serialize/1)})
    end
  end

  def show(conn, %{"id" => id, "building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    doc = WrittenDocuments.get_written_document!(id)

    with :ok <- authorize_member(conn, building_id, user) do
      cond do
        doc.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Document introuvable"}) |> halt()

        doc.status != :published and not editor?(building_id, user) ->
          conn |> put_status(:not_found) |> json(%{error: "Document introuvable"}) |> halt()

        true ->
          json(conn, %{data: serialize(doc)})
      end
    end
  end

  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_editor(conn, building_id, user) do
      attrs = take_string_keys(params, ~w(title content category is_pinned))

      case WrittenDocuments.create_written_document(building_id, user.id, attrs) do
        {:ok, doc} ->
          doc = KomunBackend.Repo.preload(doc, :author)
          conn |> put_status(:created) |> json(%{data: serialize(doc)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: format_errors(changeset)})
      end
    end
  end

  def update(conn, %{"id" => id, "building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    doc = WrittenDocuments.get_written_document!(id)

    with :ok <- authorize_editor(conn, building_id, user),
         :ok <- ensure_same_building(conn, doc, building_id) do
      attrs = take_string_keys(params, ~w(title content category is_pinned))

      case WrittenDocuments.update_written_document(doc, attrs) do
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
    doc = WrittenDocuments.get_written_document!(id)

    with :ok <- authorize_editor(conn, building_id, user),
         :ok <- ensure_same_building(conn, doc, building_id) do
      {:ok, _} = WrittenDocuments.delete_written_document(doc)
      send_resp(conn, :no_content, "")
    end
  end

  def transition(conn, %{"id" => id, "building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    doc = WrittenDocuments.get_written_document!(id)

    with :ok <- authorize_editor(conn, building_id, user),
         :ok <- ensure_same_building(conn, doc, building_id),
         {:ok, status} <- parse_status(Map.get(params, "status")) do
      reviewer_note = Map.get(params, "reviewer_note")

      case WrittenDocuments.transition(doc, status, reviewer_note) do
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
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Statut invalide"}) |> halt()

      other ->
        other
    end
  end

  def archive(conn, %{"id" => id, "building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    doc = WrittenDocuments.get_written_document!(id)

    with :ok <- authorize_editor(conn, building_id, user),
         :ok <- ensure_same_building(conn, doc, building_id) do
      case WrittenDocuments.archive(doc) do
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

  def unarchive(conn, %{"id" => id, "building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    doc = WrittenDocuments.get_written_document!(id)

    with :ok <- authorize_editor(conn, building_id, user),
         :ok <- ensure_same_building(conn, doc, building_id) do
      case WrittenDocuments.unarchive(doc) do
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
      |> json(%{error: "Seuls le syndic et le conseil syndical peuvent gérer les documents rédigés."})
      |> halt()
    end
  end

  defp editor?(building_id, user) do
    member_role = Buildings.get_member_role(building_id, user.id)

    user.role == :super_admin or
      user.role in WrittenDocuments.editor_roles() or
      member_role in WrittenDocuments.editor_roles()
  end

  defp ensure_same_building(conn, doc, building_id) do
    if doc.building_id == building_id do
      :ok
    else
      conn |> put_status(:not_found) |> json(%{error: "Document introuvable"}) |> halt()
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

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy("1"), do: true
  defp truthy(_), do: false

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
