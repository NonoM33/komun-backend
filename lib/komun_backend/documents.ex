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

  When `:question` is provided in `opts`, paragraphs whose tokens overlap
  the question are surfaced first inside each document. This protects the
  retrieval against the `max_chars` cap on long règlements (>60K chars):
  the section that actually answers the resident is kept, instead of
  silently being truncated because it sits at the end of the file.

  Backward-compatible: callers still passing an integer as the third
  argument receive the legacy concat behavior with that custom cap.
  """
  def context_for_ai(building_id, role, opts \\ [])

  def context_for_ai(building_id, role, max_chars)
      when is_atom(role) and is_integer(max_chars) do
    context_for_ai(building_id, role, max_chars: max_chars)
  end

  def context_for_ai(building_id, role, opts) when is_atom(role) and is_list(opts) do
    max_chars = Keyword.get(opts, :max_chars, 60_000)
    question = Keyword.get(opts, :question)

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

    docs = Repo.all(query)

    case relevance_tokens(question) do
      [] -> build_concat_context(docs, max_chars)
      tokens -> build_ranked_context(docs, tokens, max_chars)
    end
  end

  # ── AI context assembly ───────────────────────────────────────────────────

  defp build_concat_context(docs, max_chars) do
    docs
    |> Enum.reduce({[], 0}, fn {title, category, text}, {acc, used} ->
      remaining = max_chars - used

      if remaining <= 0 do
        {acc, used}
      else
        snippet =
          if String.length(text) > remaining,
            do: String.slice(text, 0, remaining),
            else: text

        entry = "## #{title} (#{category})\n\n#{snippet}\n"
        {[entry | acc], used + String.length(entry)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n---\n\n")
  end

  # Question-aware assembly. Within each document, score paragraphs by
  # overlap with the question's tokens, keep an opening "head" of the
  # document for general context (table of contents, preamble), then
  # interleave the highest-scoring paragraphs in original order. If no
  # paragraph in the doc matches, fall back to the head only.
  defp build_ranked_context(docs, tokens, max_chars) do
    doc_count = max(length(docs), 1)
    budget_per_doc = max(1_500, div(max_chars, doc_count))

    docs
    |> Enum.map(fn {title, category, text} ->
      snippet = pick_relevant_snippet(text, tokens, budget_per_doc)
      "## #{title} (#{category})\n\n#{snippet}\n"
    end)
    |> Enum.reduce({[], 0}, fn entry, {acc, used} ->
      remaining = max_chars - used

      cond do
        remaining <= 0 ->
          {acc, used}

        String.length(entry) > remaining ->
          {[String.slice(entry, 0, remaining) | acc], max_chars}

        true ->
          {[entry | acc], used + String.length(entry)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n---\n\n")
  end

  defp pick_relevant_snippet(text, tokens, budget) do
    if String.length(text) <= budget do
      # Whole doc fits — no need to rank, give the model everything.
      text
    else
      paragraphs =
        text
        |> String.split(~r/\n{2,}/)
        |> Enum.with_index()
        |> Enum.map(fn {p, idx} ->
          trimmed = String.trim(p)
          {idx, trimmed, score_paragraph(trimmed, tokens)}
        end)
        |> Enum.reject(fn {_idx, p, _score} -> p == "" end)

      matching = Enum.filter(paragraphs, fn {_, _, score} -> score > 0 end)

      if matching == [] do
        # No keyword match — give the head as a best-effort fallback.
        String.slice(text, 0, budget)
      else
        head_budget = min(1_200, div(budget, 4))
        head = String.slice(text, 0, head_budget)
        body_budget = budget - head_budget - 30

        selected =
          matching
          |> Enum.sort_by(fn {_idx, _p, score} -> -score end)
          |> take_within_budget(body_budget)
          |> Enum.sort_by(fn {idx, _p, _score} -> idx end)
          |> Enum.map(fn {_idx, p, _score} -> p end)
          |> Enum.join("\n\n")

        if selected == "" do
          String.slice(text, 0, budget)
        else
          head <> "\n\n[…]\n\n" <> selected
        end
      end
    end
  end

  defp take_within_budget(sorted_paragraphs, max) do
    {kept, _} =
      Enum.reduce_while(sorted_paragraphs, {[], 0}, fn {idx, p, score}, {acc, used} ->
        len = String.length(p) + 2

        cond do
          used + len > max and acc == [] -> {:halt, {[{idx, p, score}], len}}
          used + len > max -> {:halt, {acc, used}}
          true -> {:cont, {[{idx, p, score} | acc], used + len}}
        end
      end)

    kept
  end

  defp score_paragraph(paragraph, tokens) do
    paragraph_tokens = tokenize(paragraph)
    Enum.count(tokens, &MapSet.member?(paragraph_tokens, &1))
  end

  defp relevance_tokens(nil), do: []
  defp relevance_tokens(""), do: []

  defp relevance_tokens(question) when is_binary(question) do
    question
    |> tokenize()
    |> MapSet.reject(&stopword?/1)
    |> MapSet.to_list()
  end

  defp relevance_tokens(_), do: []

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> MapSet.new()
  end

  # Common French stop-words plus a few question scaffolding words. We
  # don't aim for a linguistically clean list — just to avoid scoring
  # paragraphs on filler that appears in every clause.
  @stopwords MapSet.new(~w(
    les des une dans pour avec sans sont vous nous mais elle dont leur
    sur sous par cette ces qui que quoi quand est etre faire avoir aux
    aussi tout tous toute toutes alors plus moins comme bien donc encore
    cela votre notre mes mon ton son sa ses leurs lors entre puis ainsi
    ont avait auront seront serait selon afin lorsque tandis
  ))

  defp stopword?(token), do: MapSet.member?(@stopwords, token)
end
