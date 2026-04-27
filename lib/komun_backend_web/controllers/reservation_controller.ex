defmodule KomunBackendWeb.ReservationController do
  @moduledoc """
  Endpoints des réservations (places de recharge en V1).

  Routes (toutes derrière auth) :
  - `GET    /api/v1/buildings/:building_id/charging-spots`
  - `GET    /api/v1/lots/:lot_id/reservations?from=...&until=...`
  - `POST   /api/v1/lots/:lot_id/reservations`
  - `GET    /api/v1/me/reservations`
  - `DELETE /api/v1/reservations/:id`

  Le contrôleur ne fait QUE de la validation HTTP + sérialisation.
  Toute la logique métier est dans `KomunBackend.Reservations`.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Repo, Reservations}
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.Lot
  alias KomunBackend.Reservations.Reservation

  # GET /api/v1/buildings/:building_id/charging-spots
  def list_charging_spots(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_member(conn, building_id, user) do
      spots = Reservations.list_charging_spots(building_id)
      json(conn, %{data: Enum.map(spots, &lot_json/1)})
    end
  end

  # GET /api/v1/lots/:lot_id/reservations?from=...&until=...
  def list_for_lot(conn, %{"lot_id" => lot_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with %Lot{} = lot <- Repo.get(Lot, lot_id),
         :ok <- authorize_member(conn, lot.building_id, user),
         {:ok, from} <- parse_dt(params["from"], days_ago: 0),
         {:ok, until} <- parse_dt(params["until"], days_ago: -7) do
      list = Reservations.list_reservations_for_lot(lot.id, from, until)
      json(conn, %{data: Enum.map(list, &reservation_json/1)})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Lot not found"})

      {:error, :bad_date} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid date format"})

      _ ->
        conn
    end
  end

  # POST /api/v1/lots/:lot_id/reservations
  def create(conn, %{"lot_id" => lot_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = params["reservation"] || %{}

    case Reservations.create_reservation(user.id, lot_id, attrs) do
      {:ok, reservation} ->
        conn
        |> put_status(:created)
        |> json(%{data: reservation_json(Repo.preload(reservation, [:user]))})

      {:error, :lot_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Lot not found"})

      {:error, :not_member} ->
        conn |> put_status(:forbidden) |> json(%{error: "Not a member of this building"})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})
    end
  end

  # GET /api/v1/me/reservations
  def list_mine(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    list = Reservations.list_upcoming_for_user(user.id)
    json(conn, %{data: Enum.map(list, &reservation_json/1)})
  end

  # DELETE /api/v1/reservations/:id
  def cancel(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case Reservations.cancel_reservation(id, user.id) do
      {:ok, reservation} ->
        json(conn, %{data: reservation_json(reservation)})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"})
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp authorize_member(conn, building_id, user) do
    cond do
      user.role == :super_admin -> :ok
      Buildings.member?(building_id, user.id) -> :ok
      true -> conn |> put_status(403) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp parse_dt(nil, days_ago: offset) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, DateTime.add(now, offset * 86_400, :second)}
  end

  defp parse_dt(value, _) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> {:error, :bad_date}
    end
  end

  defp lot_json(%Lot{} = lot) do
    %{
      id: lot.id,
      number: lot.number,
      floor: lot.floor,
      type: lot.type,
      is_charging_spot: lot.is_charging_spot
    }
  end

  defp reservation_json(%Reservation{} = r) do
    user_payload =
      case r.user do
        %Ecto.Association.NotLoaded{} ->
          nil

        nil ->
          nil

        u ->
          %{
            id: u.id,
            email: u.email,
            first_name: u.first_name,
            last_name: u.last_name
          }
      end

    lot_payload =
      case r.lot do
        %Ecto.Association.NotLoaded{} -> nil
        nil -> nil
        lot -> lot_json(lot)
      end

    %{
      id: r.id,
      lot_id: r.lot_id,
      user_id: r.user_id,
      building_id: r.building_id,
      starts_at: r.starts_at,
      ends_at: r.ends_at,
      status: r.status,
      kind: r.kind,
      notes: r.notes,
      lot: lot_payload,
      user: user_payload,
      inserted_at: r.inserted_at
    }
  end

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
