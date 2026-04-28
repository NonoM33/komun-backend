defmodule KomunBackend.Assistant do
  @moduledoc """
  Assistant context — fronts the Groq-backed AI helper for residents.

  Rate limiting
  -------------
  Every resident is allowed **one successful question per 24h** against the
  live model. We track this on `users.last_chat_at`; super_admin bypasses
  the limit so we can smoke-test in prod. Failed calls (network errors,
  Groq 5xx) don't consume the quota.

  Conversations
  -------------
  Questions are grouped into `AssistantConversation` threads (one user ×
  one building × N threads) so the UI can show a ChatGPT-style sidebar
  and keep each thread's context independent. When `ask_in_conversation/4`
  is called with a conversation_id that doesn't belong to the caller we
  refuse with `:not_found` — a user can only talk in their own threads.

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
  alias KomunBackend.Assistant.{AssistantMessage, Conversation}

  @rate_limit_window_hours 24
  @max_question_length 2_000
  @history_turns 6

  @system_prompt """
  Tu es l'assistant virtuel de Komun, une plateforme de copropriété. Tu
  réponds UNIQUEMENT en français, de manière claire et concise. Ta réponse
  doit s'appuyer sur les documents fournis entre les balises
  <documents>…</documents> (règlement de copropriété, PV, contrats, etc.).

  Règles générales :
  - Si la réponse est dans les documents, cite la section concernée (titre
    du document + article/point si possible).
  - Ne fabrique JAMAIS un article du règlement, un numéro d'article du Code
    civil, ou une décision d'AG qui n'est pas dans les documents. Si tu
    doutes d'un numéro précis, ne le cite pas.
  - Reste courtois et neutre. Pas d'emoji.
  - Réponds en 150 mots maximum sauf si une liste structurée est nécessaire.

  Quand les documents ne couvrent PAS le sujet :
  Ne te contente JAMAIS d'un « pas d'information ». Applique d'abord les
  principes de bon sens et le droit commun du voisinage français, qui
  s'appliquent par défaut à toute copropriété même sans clause au
  règlement. Mets en avant la règle pertinente parmi celles-ci :

  - **Troubles anormaux du voisinage** : nul ne doit causer à autrui un
    trouble qui dépasse les inconvénients normaux du voisinage (principe
    général reconnu par la jurisprudence française). Couvre les nuisances
    olfactives (fumée de cigarette/barbecue récurrente vers les fenêtres
    voisines, odeurs persistantes), sonores (bruit, musique, animaux la
    nuit, talons sur parquet), visuelles (linge sur balcon façade rue),
    et environnementales (déchets, encombrants laissés en parties communes).
  - **Tabac dans les jardins / parties privatives extérieures** : autorisé
    TANT QUE personne ne s'en plaint. Dès qu'un voisin signale formellement
    la gêne (mail, courrier, signalement au syndic), elle est qualifiée
    de trouble anormal du voisinage : l'arrêt devient exigible. La
    jurisprudence française est constante. Pas de zone grise : une plainte
    formelle = obligation d'arrêter. Le voisin gêné peut, dans l'ordre :
    écrire au fumeur, saisir le conseil syndical / syndic, puis en
    dernier recours saisir le tribunal judiciaire en référé.
  - **Tabac dans les parties communes fermées** : interdit par la loi
    (décret 2006-1386, dit « décret tabac ») — halls, cages d'escalier,
    couloirs, ascenseurs, locaux poubelles.
  - **Bruit** : tapage diurne ET nocturne sont sanctionnés (Code de la
    santé publique). Les horaires « calmes » dépendent souvent d'un
    arrêté préfectoral local.
  - **Animaux** : autorisés en principe sauf clause contraire au
    règlement (loi du 9 juillet 1970, art. 10), mais ils ne doivent pas
    causer de trouble (aboiements, odeurs).
  - **Barbecue / plancha sur balcon** : pas interdit en soi, mais soumis
    aux mêmes règles de trouble anormal + parfois interdit par
    arrêté municipal en période de sécheresse.
  - **Parties communes** (couloirs, halls, paliers, locaux vélos) : ne
    peuvent pas être appropriées (pas de meuble, vélo, poussette qui
    encombrent durablement) — usage commun par nature.

  Format quand les documents ne couvrent pas :
  1. **« Le règlement ne traite pas explicitement ce point. »** (1 ligne)
  2. Règle générale qui s'applique par défaut (citer les principes
     ci-dessus, sans inventer de numéro d'article précis si tu n'es pas
     sûr — préfère « le droit commun du voisinage prévoit que… »).
  3. Conséquence pratique CLAIRE et DIRECTE — si la règle interdit ou
     limite, dis-le sans atténuer (« c'est interdit », « il faut arrêter »,
     « le voisin peut exiger l'arrêt »). Si le résident s'est plaint, c'est
     qu'il y a déjà gêne caractérisée — réponds en conséquence, pas en
     théorie. Pas de « peut-être », pas de « éventuellement », pas de
     « il convient de ». Le résident vient sur Komun pour avoir un avis
     tranché, pas une dissertation neutre.
  4. **« Pour une réponse formelle propre à votre copropriété,
     contactez votre syndic. »**

  Ne renvoie JAMAIS l'utilisateur vers le syndic sans lui avoir d'abord
  donné la règle de bon sens applicable — c'est ça qui crée de la valeur.
  """

  def rate_limit_window_hours, do: @rate_limit_window_hours

  # ── Conversations ─────────────────────────────────────────────────────────

  @doc """
  Lists the conversations for `user_id` in `building_id`, ordered by
  most-recently-active first.
  """
  def list_conversations(user_id, building_id) do
    from(c in Conversation,
      where: c.user_id == ^user_id and c.building_id == ^building_id,
      order_by: [
        desc: coalesce(c.last_message_at, c.inserted_at),
        desc: c.inserted_at
      ]
    )
    |> Repo.all()
  end

  @doc """
  Fetches a conversation and its messages if it belongs to `user_id` in
  `building_id`. Returns `{:ok, conversation}` or `{:error, :not_found}`.
  """
  def get_conversation(user_id, building_id, conversation_id) do
    case safe_get_conversation(user_id, building_id, conversation_id) do
      nil ->
        {:error, :not_found}

      conv ->
        msgs =
          from(m in AssistantMessage,
            where: m.conversation_id == ^conv.id,
            order_by: [asc: m.inserted_at]
          )
          |> Repo.all()

        {:ok, %{conv | messages: msgs}}
    end
  end

  @doc """
  Creates an empty conversation for `user` in `building_id`. Membership
  is enforced via `authorize_member/2`.
  """
  def create_conversation(user, building_id, attrs \\ %{}) do
    with :ok <- authorize_member(user, building_id) do
      %Conversation{}
      |> Conversation.changeset(
        Map.merge(%{"user_id" => user.id, "building_id" => building_id}, attrs)
      )
      |> Repo.insert()
    end
  end

  @doc """
  Deletes a conversation if it belongs to `user_id` in `building_id`.
  Cascade on `assistant_messages.conversation_id` removes its messages
  too. Returns `:ok` or `{:error, :not_found}`.
  """
  def delete_conversation(user_id, building_id, conversation_id) do
    case safe_get_conversation(user_id, building_id, conversation_id) do
      nil ->
        {:error, :not_found}

      conv ->
        {:ok, _} = Repo.delete(conv)
        :ok
    end
  end

  @doc """
  Asks a question inside an existing conversation. Same error contract as
  `ask/3`, plus `{:error, :not_found}` if the conversation doesn't belong
  to the user in this building. Returns `{:ok, %{message, conversation}}`
  on success so the controller can echo the refreshed conversation (the
  title may have been derived from the first question).
  """
  def ask_in_conversation(user, building_id, conversation_id, question) do
    with :ok <- validate_question(question),
         :ok <- authorize_member(user, building_id),
         {:ok, conv} <- load_owned_conversation(user.id, building_id, conversation_id),
         :ok <- check_rate_limit(user) do
      context = Documents.context_for_ai(building_id, user.role)
      history = load_history_messages(conv.id)

      messages =
        [%{role: :system, content: @system_prompt}] ++
          history ++
          [%{role: :user, content: build_user_prompt(context, question)}]

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
              user_id: user.id,
              conversation_id: conv.id
            })
            |> Repo.insert()

          Accounts.touch_last_chat_at(user)

          updated_conv = touch_conversation(conv, question)
          {:ok, %{message: msg, conversation: updated_conv}}

        {:error, :missing_api_key} ->
          {:error, :missing_api_key}

        {:error, reason} ->
          persist_failure(user, building_id, question, reason, conv.id)
          {:error, reason}
      end
    end
  end

  # ── Legacy single-thread API ─────────────────────────────────────────────

  @doc """
  Legacy single-thread ask. Kept for any remaining callers — new clients
  should use `ask_in_conversation/4`.
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
          persist_failure(user, building_id, question, reason, nil)
          {:error, reason}
      end
    end
  end

  @doc "Lists the user's 20 most recent questions in a building (legacy)."
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

  defp safe_get_conversation(user_id, building_id, conversation_id) do
    Repo.get_by(Conversation,
      id: conversation_id,
      user_id: user_id,
      building_id: building_id
    )
  rescue
    Ecto.Query.CastError -> nil
  end

  defp load_owned_conversation(user_id, building_id, conversation_id) do
    case safe_get_conversation(user_id, building_id, conversation_id) do
      nil -> {:error, :not_found}
      conv -> {:ok, conv}
    end
  end

  defp load_history_messages(conversation_id) do
    from(m in AssistantMessage,
      where: m.conversation_id == ^conversation_id and m.status == "ok",
      order_by: [desc: m.inserted_at],
      limit: ^@history_turns
    )
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.flat_map(fn m ->
      user_turn = %{role: :user, content: m.question || ""}

      case m.answer do
        nil -> [user_turn]
        "" -> [user_turn]
        ans -> [user_turn, %{role: :assistant, content: ans}]
      end
    end)
  end

  defp touch_conversation(%Conversation{} = conv, first_question) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      "last_message_at" => now,
      "message_count" => (conv.message_count || 0) + 1
    }

    attrs =
      case conv.title do
        nil -> Map.put(attrs, "title", derive_title(first_question))
        "Nouvelle conversation" -> Map.put(attrs, "title", derive_title(first_question))
        "" -> Map.put(attrs, "title", derive_title(first_question))
        _ -> attrs
      end

    {:ok, updated} =
      conv
      |> Conversation.changeset(attrs)
      |> Repo.update()

    updated
  end

  defp derive_title(question) do
    trimmed =
      question
      |> to_string()
      |> String.trim()
      |> String.replace(~r/\s+/, " ")
      |> String.slice(0, 80)

    if trimmed == "", do: "Nouvelle conversation", else: trimmed
  end

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

  defp persist_failure(user, building_id, question, reason, conversation_id) do
    %AssistantMessage{}
    |> AssistantMessage.changeset(%{
      question: question,
      answer: nil,
      status: "failed",
      error: inspect(reason),
      building_id: building_id,
      user_id: user.id,
      conversation_id: conversation_id
    })
    |> Repo.insert()
  end
end
