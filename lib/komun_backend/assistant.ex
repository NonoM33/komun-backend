defmodule KomunBackend.Assistant do
  @moduledoc """
  Assistant context — fronts the Groq-backed AI helper for residents.

  Rate limiting
  -------------
  Every resident is allowed **one successful question per 24h** against the
  live model. We track this on `users.last_chat_at`; super_admin bypasses
  the limit so we can smoke-test in prod. Failed calls (network errors,
  Groq 5xx) don't consume the quota.

  Context assembly
  ----------------
  Each question is grounded on the residence's own documents, filtered by
  role via `Documents.context_for_ai/3`:

  - Residents (locataire / coproprietaire / gardien / prestataire)
    → règlement de copropriété only.
  - Conseil + syndic + admin → règlement + PV + every other document with
    extracted text.

  If no grounding text is available yet, we still answer — but the system
  prompt instructs the model to flag the gap so the syndic takes the hint.
  """

  require Logger

  import Ecto.Query
  alias KomunBackend.{Accounts, AI, Buildings, Documents, Repo}
  alias KomunBackend.Assistant.AssistantMessage

  @rate_limit_window_hours 24
  @max_question_length 2_000

  @system_prompt """
  Tu es l'assistant virtuel de Komun, une plateforme de copropriété. Tu
  réponds UNIQUEMENT en français, de manière claire et concise. Ta réponse
  doit s'appuyer sur les documents fournis entre les balises
  <documents>…</documents> (règlement de copropriété, PV, contrats, etc.).

  Règles :
  - Si la réponse est dans les documents, cite la section concernée (titre
    du document + article/point si possible).
  - Si la question concerne un sujet non couvert par les documents, réponds
    de manière générale puis indique « Je n'ai pas trouvé cette information
    dans les documents indexés, contactez votre syndic pour confirmation. »
  - Ne fabrique JAMAIS un article ou une décision qui n'est pas dans les
    documents.
  - Reste courtois et neutre. Pas d'emoji.
  - Réponds en 150 mots maximum sauf si une liste structurée est nécessaire.
  """

  def rate_limit_window_hours, do: @rate_limit_window_hours

  @doc """
  Ask the assistant a question. Returns:

  - `{:ok, assistant_message}` — answer stored, rate limit consumed.
  - `{:error, :rate_limited, %{next_allowed_at: DateTime}}` — quota spent.
  - `{:error, :not_a_member}` — user doesn't belong to the building.
  - `{:error, :missing_api_key}` — Groq not configured.
  - `{:error, :empty_question}` / `{:error, :question_too_long}` — client error.
  - `{:error, reason}` — upstream failure, quota not consumed.
  """
  def ask(user, building_id, question) do
    with :ok <- validate_question(question),
         :ok <- authorize_member(user, building_id),
         :ok <- check_rate_limit(user) do
      context = Documents.context_for_ai(building_id, user.role)

      messages = [
        %{role: :system, content: @system_prompt},
        %{role: :user, content: build_user_prompt(context, question)}
      ]

      case AI.Groq.complete(messages) do
        {:ok, %{content: answer, model: model, usage: usage}} ->
          {:ok, msg} =
            %AssistantMessage{}
            |> AssistantMessage.changeset(%{
              question: question,
              answer: answer,
              model: model,
              tokens_prompt: usage.prompt,
              tokens_completion: usage.completion,
              status: "ok",
              building_id: building_id,
              user_id: user.id
            })
            |> Repo.insert()

          Accounts.touch_last_chat_at(user)

          {:ok, msg}

        {:error, :missing_api_key} ->
          {:error, :missing_api_key}

        {:error, reason} ->
          persist_failure(user, building_id, question, reason)
          {:error, reason}
      end
    end
  end

  @doc "Lists the user's 20 most recent questions in a building."
  def list_recent(user_id, building_id, limit \\ 20) do
    from(m in AssistantMessage,
      where: m.user_id == ^user_id and m.building_id == ^building_id,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Computes when the user is next allowed to ask a question."
  def next_allowed_at(%{last_chat_at: nil}), do: DateTime.utc_now()

  def next_allowed_at(%{last_chat_at: last}) do
    DateTime.add(last, @rate_limit_window_hours * 3600, :second)
  end

  def next_allowed_at(_), do: DateTime.utc_now()

  # ── Private ──────────────────────────────────────────────────────────────

  defp validate_question(q) when is_binary(q) do
    trimmed = String.trim(q)

    cond do
      trimmed == "" -> {:error, :empty_question}
      String.length(trimmed) > @max_question_length -> {:error, :question_too_long}
      true -> :ok
    end
  end

  defp validate_question(_), do: {:error, :empty_question}

  defp authorize_member(%{role: :super_admin}, _building_id), do: :ok

  defp authorize_member(user, building_id) do
    if Buildings.member?(building_id, user.id), do: :ok, else: {:error, :not_a_member}
  end

  defp check_rate_limit(%{role: :super_admin}), do: :ok

  defp check_rate_limit(%{last_chat_at: nil}), do: :ok

  defp check_rate_limit(%{last_chat_at: last} = user) do
    threshold = DateTime.add(DateTime.utc_now(), -@rate_limit_window_hours * 3600, :second)

    if DateTime.compare(last, threshold) == :lt do
      :ok
    else
      {:error, :rate_limited, %{next_allowed_at: next_allowed_at(user)}}
    end
  end

  defp build_user_prompt("", question) do
    """
    Je n'ai pas encore de document de référence indexé pour cette résidence.

    Question : #{question}
    """
  end

  defp build_user_prompt(context, question) do
    """
    <documents>
    #{context}
    </documents>

    Question : #{question}
    """
  end

  defp persist_failure(user, building_id, question, reason) do
    %AssistantMessage{}
    |> AssistantMessage.changeset(%{
      question: question,
      answer: nil,
      status: "failed",
      error: inspect(reason),
      building_id: building_id,
      user_id: user.id
    })
    |> Repo.insert()
  end
end
