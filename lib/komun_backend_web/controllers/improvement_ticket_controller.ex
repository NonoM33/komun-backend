defmodule KomunBackendWeb.ImprovementTicketController do
  use KomunBackendWeb, :controller

  alias KomunBackend.ImprovementTickets
  alias KomunBackend.ImprovementTickets.ImprovementTicket
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/improvement_tickets
  # Liste les tickets ouverts par l'utilisateur courant.
  def index(conn, params) do
    user = Guardian.Plug.current_resource(conn)
    tickets = ImprovementTickets.list_by_author(user.id, params)
    json(conn, %{data: Enum.map(tickets, &ticket_json/1)})
  end

  # GET /api/v1/improvement_tickets/:id
  # Détail d'un ticket — réservé à l'auteur ou aux super_admin.
  def show(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case ImprovementTickets.get_ticket(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

      ticket ->
        if user.role == :super_admin or to_string(ticket.author_id) == to_string(user.id) do
          ticket = KomunBackend.Repo.preload(ticket, [:author, :building])
          json(conn, %{data: ticket_json(ticket)})
        else
          conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()
        end
    end
  end

  # POST /api/v1/improvement_tickets
  def create(conn, %{"ticket" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    # Le building courant est utile en contexte mais pas requis.
    # On l'accepte depuis le payload (le front passe le bâtiment
    # actif), null par défaut.
    building_id = Map.get(attrs, "building_id")

    case ImprovementTickets.create_ticket(user.id, attrs, building_id) do
      {:ok, ticket} ->
        conn
        |> put_status(:created)
        |> json(%{data: ticket_json(ticket)})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})
        |> halt()
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @doc false
  def ticket_json(%ImprovementTicket{} = t) do
    %{
      id: t.id,
      kind: t.kind,
      title: t.title,
      description: t.description,
      status: t.status,
      admin_note: t.admin_note,
      author: maybe_user(t.author),
      building_id: t.building_id,
      resolved_at: t.resolved_at,
      inserted_at: t.inserted_at,
      updated_at: t.updated_at
    }
  end

  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(nil), do: nil

  defp maybe_user(u),
    do: %{
      id: u.id,
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name,
      avatar_url: u.avatar_url
    }

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
