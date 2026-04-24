defmodule KomunBackendWeb.AssistantController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Assistant
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/buildings/:building_id/assistant/history  (legacy)
  def history(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    messages = Assistant.list_recent(user.id, building_id)

    json(conn, %{
      data: Enum.map(messages, &serialize_message/1),
      rate_limit: rate_limit_info(user)
    })
  end

  # GET /api/v1/buildings/:building_id/assistant/status
  # The frontend's useAssistantStatus reads the object directly (no `data`
  # wrapper), so we mirror the rate_limit_info shape at the top level.
  def status(conn, %{"building_id" => _building_id}) do
    user = Guardian.Plug.current_resource(conn)
    json(conn, rate_limit_info(user))
  end

  # GET /api/v1/buildings/:building_id/assistant/conversations
  def list_conversations(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    conversations = Assistant.list_conversations(user.id, building_id)

    json(conn, %{
      data: Enum.map(conversations, &serialize_conversation/1),
      rate_limit: rate_limit_info(user)
    })
  end

  # POST /api/v1/buildings/:building_id/assistant/conversations
  def create_conversation(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Assistant.create_conversation(user, building_id) do
      {:ok, conv} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: serialize_conversation(conv),
          rate_limit: rate_limit_info(user)
        })

      {:error, :not_a_member} ->
        conn |> put_status(403) |> json(%{error: "not_a_member"})

      {:error, %Ecto.Changeset{} = cs} ->
        conn |> put_status(422) |> json(%{error: "invalid", detail: inspect(cs.errors)})
    end
  end

  # GET /api/v1/buildings/:building_id/assistant/conversations/:id
  def show_conversation(conn, %{"building_id" => building_id, "id" => conversation_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Assistant.get_conversation(user.id, building_id, conversation_id) do
      {:ok, conv} ->
        json(conn, %{
          data: %{
            id: conv.id,
            title: conv.title,
            created_at: conv.inserted_at,
            last_message_at: conv.last_message_at,
            message_count: conv.message_count || 0,
            messages: Enum.map(conv.messages, &serialize_message/1)
          },
          rate_limit: rate_limit_info(user)
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  # DELETE /api/v1/buildings/:building_id/assistant/conversations/:id
  def delete_conversation(conn, %{"building_id" => building_id, "id" => conversation_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Assistant.delete_conversation(user.id, building_id, conversation_id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  # POST /api/v1/buildings/:building_id/assistant/conversations/:id/ask
  def ask_in_conversation(
        conn,
        %{"building_id" => building_id, "id" => conversation_id, "question" => question}
      ) do
    user = Guardian.Plug.current_resource(conn)

    case Assistant.ask_in_conversation(user, building_id, conversation_id, question) do
      {:ok, %{message: msg, conversation: conv}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: serialize_message(msg),
          conversation: serialize_conversation(conv),
          rate_limit: rate_limit_info(%{user | last_chat_at: msg.inserted_at})
        })

      result ->
        handle_ask_error(conn, result)
    end
  end

  def ask_in_conversation(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_question"})
  end

  # POST /api/v1/buildings/:building_id/assistant/ask  (legacy)
  def ask(conn, %{"building_id" => building_id, "question" => question}) do
    user = Guardian.Plug.current_resource(conn)

    case Assistant.ask(user, building_id, question) do
      {:ok, msg} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: serialize_message(msg),
          rate_limit: rate_limit_info(%{user | last_chat_at: msg.inserted_at})
        })

      result ->
        handle_ask_error(conn, result)
    end
  end

  def ask(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_question"})
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp handle_ask_error(conn, {:error, :rate_limited, %{next_allowed_at: at}}) do
    conn
    |> put_status(429)
    |> json(%{
      error: "rate_limited",
      next_allowed_at: at,
      window_hours: Assistant.rate_limit_window_hours()
    })
  end

  defp handle_ask_error(conn, {:error, :not_a_member}),
    do: conn |> put_status(403) |> json(%{error: "not_a_member"})

  defp handle_ask_error(conn, {:error, :not_found}),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp handle_ask_error(conn, {:error, :missing_api_key}) do
    conn
    |> put_status(503)
    |> json(%{
      error: "ai_not_configured",
      message: "L'assistant n'est pas encore configuré."
    })
  end

  defp handle_ask_error(conn, {:error, :empty_question}),
    do: conn |> put_status(422) |> json(%{error: "empty_question"})

  defp handle_ask_error(conn, {:error, :question_too_long}),
    do: conn |> put_status(422) |> json(%{error: "question_too_long"})

  defp handle_ask_error(conn, {:error, reason}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "upstream_error", detail: to_string(reason)})
  end

  defp serialize_message(msg) do
    %{
      id: msg.id,
      conversation_id: Map.get(msg, :conversation_id),
      question: msg.question,
      answer: msg.answer,
      model: msg.model,
      status: msg.status,
      error: msg.error,
      created_at: msg.inserted_at,
      inserted_at: msg.inserted_at,
      tokens: %{prompt: msg.tokens_prompt, completion: msg.tokens_completion}
    }
  end

  defp serialize_conversation(conv) do
    %{
      id: conv.id,
      title: conv.title,
      created_at: conv.inserted_at,
      last_message_at: conv.last_message_at,
      message_count: conv.message_count || 0
    }
  end

  defp rate_limit_info(user) do
    now = DateTime.utc_now()
    last_chat_at = Map.get(user, :last_chat_at)
    role = Map.get(user, :role)

    available? =
      cond do
        role == :super_admin -> true
        is_nil(last_chat_at) -> true
        true ->
          next = Assistant.next_allowed_at(user)
          DateTime.compare(next, now) != :gt
      end

    %{
      window_hours: Assistant.rate_limit_window_hours(),
      available: available?,
      next_allowed_at: if(available?, do: nil, else: Assistant.next_allowed_at(user)),
      last_chat_at: last_chat_at
    }
  end
end
