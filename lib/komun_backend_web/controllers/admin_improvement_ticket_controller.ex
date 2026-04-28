defmodule KomunBackendWeb.AdminImprovementTicketController do
  @moduledoc """
  Console admin pour les tickets de feedback produit. Toutes les
  routes sont déjà gardées par le pipeline `:require_super_admin`
  côté router — pas besoin de re-vérifier ici.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.ImprovementTickets
  alias KomunBackendWeb.ImprovementTicketController

  # GET /api/v1/admin/improvement_tickets
  def index(conn, params) do
    tickets = ImprovementTickets.list_all(params)
    json(conn, %{data: Enum.map(tickets, &ImprovementTicketController.ticket_json/1)})
  end

  # PATCH /api/v1/admin/improvement_tickets/:id
  def update(conn, %{"id" => id, "ticket" => attrs}) do
    case ImprovementTickets.get_ticket(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

      ticket ->
        case ImprovementTickets.admin_update(ticket, attrs) do
          {:ok, updated} ->
            json(conn, %{data: ImprovementTicketController.ticket_json(updated)})

          {:error, cs} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_errors(cs)})
            |> halt()
        end
    end
  end

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
