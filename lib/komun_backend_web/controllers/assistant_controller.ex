defmodule KomunBackendWeb.AssistantController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Assistant
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/buildings/:building_id/assistant/history
  def history(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    messages = Assistant.list_recent(user.id, building_id)

    json(conn, %{
      data: Enum.map(messages, &serialize/1),
      rate_limit: rate_limit_info(user)
    })
  end

  # GET /api/v1/buildings/:building_id/assistant/status
  def status(conn, %{"building_id" => _building_id}) do
    user = Guardian.Plug.current_resource(conn)
    json(conn, %{data: rate_limit_info(user)})
  end

  # POST /api/v1/buildings/:building_id/assistant/ask
  # Body: {"question": "…"}
  def ask(conn, %{"building_id" => building_id, "question" => question}) do
    user = Guardian.Plug.current_resource(conn)

    case Assistant.ask(user, building_id, question) do
      {:ok, msg} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: serialize(msg),
          rate_limit: rate_limit_info(%{user | last_chat_at: msg.inserted_at})
        })

      {:error, :rate_limited, %{next_allowed_at: at}} ->
        conn
        |> put_status(429)
        |> json(%{
          error: "rate_limited",
          next_allowed_at: at,
          window_hours: Assistant.rate_limit_window_hours()
        })

      {:error, :not_a_member} ->
        conn
        |> put_status(403)
        |> json(%{error: "not_a_member"})

      {:error, :missing_api_key} ->
        conn
        |> put_status(503)
        |> json(%{
          error: "ai_not_configured",
          message: "L'assistant n'est pas encore configuré."
        })

      {:error, :empty_question} ->
        conn |> put_status(422) |> json(%{error: "empty_question"})

      {:error, :question_too_long} ->
        conn |> put_status(422) |> json(%{error: "question_too_long"})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "upstream_error", detail: to_string(reason)})
    end
  end

  def ask(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_question"})
  end

  defp serialize(msg) do
    %{
      id: msg.id,
      question: msg.question,
      answer: msg.answer,
      model: msg.model,
      status: msg.status,
      error: msg.error,
      inserted_at: msg.inserted_at,
      tokens: %{prompt: msg.tokens_prompt, completion: msg.tokens_completion}
    }
  end

  defp rate_limit_info(user) do
    now = DateTime.utc_now()
    next = Assistant.next_allowed_at(user)
    available? = DateTime.compare(next, now) != :gt

    %{
      window_hours: Assistant.rate_limit_window_hours(),
      available: available?,
      next_allowed_at: if(available?, do: nil, else: next),
      last_chat_at: Map.get(user, :last_chat_at)
    }
  end
end
