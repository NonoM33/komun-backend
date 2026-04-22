defmodule KomunBackend.Documents do
  @moduledoc "Documents context."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Documents.Document

  # Roles allowed to upload documents. The IncidentController-style
  # authorize_building/2 handles the building-membership check separately.
  @uploader_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  def uploader_roles, do: @uploader_roles

  def list_documents(building_id, opts \\ []) do
    include_archived? = Keyword.get(opts, :include_archived, false)

    base =
      from(d in Document,
        where: d.building_id == ^building_id and d.is_public == true,
        order_by: [desc: d.is_pinned, desc: d.inserted_at],
        preload: [:uploaded_by]
      )

    query =
      if include_archived?, do: base, else: where(base, [d], d.is_archived == false)

    Repo.all(query)
  end

  @doc "Lists archived documents only (admin / syndic review)."
  def list_archived_documents(building_id) do
    from(d in Document,
      where:
        d.building_id == ^building_id and d.is_public == true and
          d.is_archived == true,
      order_by: [desc: d.archived_at, desc: d.inserted_at],
      preload: [:uploaded_by]
    )
    |> Repo.all()
  end

  def archive_document(%Document{} = doc) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    doc
    |> Document.changeset(%{is_archived: true, archived_at: now, is_pinned: false})
    |> Repo.update()
  end

  def unarchive_document(%Document{} = doc) do
    doc
    |> Document.changeset(%{is_archived: false, archived_at: nil})
    |> Repo.update()
  end

  def list_documents_by_categories(building_id, categories) when is_list(categories) do
    from(d in Document,
      where:
        d.building_id == ^building_id and d.is_public == true and
          d.category in ^categories,
      order_by: [desc: d.is_pinned, desc: d.inserted_at],
      preload: [:uploaded_by]
    )
    |> Repo.all()
  end

  def get_document!(id), do: Repo.get!(Document, id) |> Repo.preload(:uploaded_by)

  def create_document(building_id, uploader_id, attrs) do
    %Document{}
    |> Document.changeset(
      Map.merge(attrs, %{building_id: building_id, uploaded_by_id: uploader_id})
    )
    |> Repo.insert()
  end

  def update_document(doc, attrs) do
    doc |> Document.changeset(attrs) |> Repo.update()
  end

  def delete_document(doc), do: Repo.delete(doc)

  @doc """
  Returns the mandatory-category compliance status for a building:

      [%{category: :reglement, present: true, count: 1}, ...]

  Used by the UI to flag missing core documents (règlement de copropriété).
  """
  def mandatory_status(building_id) do
    categories = Document.mandatory_categories()

    counts =
      from(d in Document,
        where:
          d.building_id == ^building_id and d.is_public == true and
            d.is_archived == false and d.category in ^categories,
        group_by: d.category,
        select: {d.category, count(d.id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(categories, fn cat ->
      count = Map.get(counts, cat, 0)
      %{category: cat, present: count > 0, count: count}
    end)
  end

  @doc """
  Returns document content text concatenated for AI grounding, in priority
  order (pinned first, then by category, then by freshness). Truncated at
  `max_chars` to stay under the model's context budget.

  Role scoping:
  - `:locataire`, `:coproprietaire`, `:gardien`, `:prestataire` see public
    documents in the `:reglement` category only.
  - `:membre_cs`, `:president_cs`, `:syndic_manager`, `:syndic_staff`,
    `:super_admin` see every public document with extracted text.
  """
  def context_for_ai(building_id, role, max_chars \\ 60_000)

  def context_for_ai(building_id, role, max_chars) when is_atom(role) do
    categories =
      case role do
        r when r in [:locataire, :coproprietaire, :gardien, :prestataire] -> [:reglement]
        _ -> nil
      end

    query =
      from(d in Document,
        where:
          d.building_id == ^building_id and d.is_public == true and
            d.is_archived == false and
            not is_nil(d.content_text) and d.content_text != "",
        order_by: [desc: d.is_pinned, asc: d.category, desc: d.inserted_at],
        select: {d.title, d.category, d.content_text}
      )

    query =
      if categories, do: where(query, [d], d.category in ^categories), else: query

    query
    |> Repo.all()
    |> Enum.reduce({[], 0}, fn {title, category, text}, {acc, used} ->
      remaining = max_chars - used
      if remaining <= 0 do
        {acc, used}
      else
        snippet = if String.length(text) > remaining, do: String.slice(text, 0, remaining), else: text
        entry = "## #{title} (#{category})\n\n#{snippet}\n"
        {[entry | acc], used + String.length(entry)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n---\n\n")
  end
end
