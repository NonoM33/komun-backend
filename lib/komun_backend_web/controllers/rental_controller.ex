defmodule KomunBackendWeb.RentalController do
  @moduledoc """
  Endpoints de la marketplace location de places.

  Routes :
  - `GET  /api/v1/buildings/:building_id/rental-spots` — places dispo à
    la location dans le bâtiment.
  - `PATCH /api/v1/lots/:id/rental` — le proprio configure son lot pour
    location (prix horaire/mensuel, description, is_rentable).
  - `POST /api/v1/lots/:lot_id/rent` — crée la réservation `:rental` +
    PaymentIntent. Retourne `{reservation, client_secret}` au frontend
    qui finit le paiement via Stripe Elements.
  - `GET  /api/v1/me/rentals` — mes locations (en tant que locataire).
  - `GET  /api/v1/me/owner-payouts` — mes encaissements (en tant que
    propriétaire).
  """

  use KomunBackendWeb, :controller

  import Ecto.Query

  alias KomunBackend.{Buildings, Payments, Repo, Reservations}
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.Lot

  def list_rental_spots(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_member(conn, building_id, user) do
      lots =
        from(l in Lot,
          where:
            l.building_id == ^building_id and
              l.is_rentable == true,
          order_by: [asc: l.number],
          preload: [:owner]
        )
        |> Repo.all()

      json(conn, %{data: Enum.map(lots, &rental_lot_json/1)})
    end
  end

  def update_lot_rental(conn, %{"id" => lot_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    lot = Repo.get!(Lot, lot_id)

    cond do
      lot.owner_id != user.id ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seul le propriétaire de la place peut la configurer"})

      true ->
        attrs = Map.take(params["lot"] || %{}, [
          "is_rentable",
          "rental_price_per_hour_cents",
          "rental_price_per_month_cents",
          "rental_description"
        ])

        case lot |> Lot.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            json(conn, %{data: rental_lot_json(updated)})

          {:error, cs} ->
            conn |> put_status(:unprocessable_entity) |> json(%{errors: errors(cs)})
        end
    end
  end

  def rent(conn, %{"lot_id" => lot_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = (params["reservation"] || %{}) |> Map.put("kind", "rental")

    with {:ok, reservation} <- Reservations.create_reservation(user.id, lot_id, attrs),
         {:ok, payment, intent} <- Payments.create_payment_for_reservation(reservation) do
      conn
      |> put_status(:created)
      |> json(%{
        data: %{
          reservation: %{id: reservation.id, status: reservation.status},
          payment: %{
            id: payment.id,
            amount_cents: payment.amount_cents,
            commission_cents: payment.commission_cents,
            currency: payment.currency,
            status: payment.status
          },
          client_secret: intent["client_secret"]
        }
      })
    else
      {:error, :not_member} ->
        conn |> put_status(:forbidden) |> json(%{error: "Vous n'êtes pas membre de ce bâtiment"})

      {:error, :lot_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Place introuvable"})

      {:error, :owner_not_onboarded} ->
        conn
        |> put_status(:precondition_failed)
        |> json(%{
          error:
            "Le propriétaire n'a pas finalisé son inscription Stripe — la location ne peut pas être encaissée."
        })

      {:error, :lot_not_rentable} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Cette place n'est pas mise en location"})

      {:error, :no_price} ->
        conn |> put_status(:bad_request) |> json(%{error: "Tarif non configuré"})

      {:error, %{type: :stripe_disabled}} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "Stripe non configuré",
          detail: "Variables d'env STRIPE_SECRET_KEY manquantes"
        })

      {:error, %{message: msg}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: msg})

      {:error, %Ecto.Changeset{} = cs} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors(cs)})
    end
  end

  def list_mine(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    payments = Payments.list_for_renter(user.id)
    json(conn, %{data: Enum.map(payments, &payment_json/1)})
  end

  def list_payouts(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    payments = Payments.list_for_owner(user.id)
    json(conn, %{data: Enum.map(payments, &payment_json/1)})
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp authorize_member(conn, building_id, user) do
    cond do
      user.role == :super_admin -> :ok
      Buildings.member?(building_id, user.id) -> :ok
      true -> conn |> put_status(403) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp rental_lot_json(%Lot{} = lot) do
    owner =
      case lot.owner do
        %Ecto.Association.NotLoaded{} ->
          nil

        nil ->
          nil

        u ->
          %{
            id: u.id,
            display_name:
              cond do
                u.first_name && u.last_name -> "#{u.first_name} #{u.last_name}"
                u.first_name -> u.first_name
                true -> u.email
              end,
            stripe_connect_status: u.stripe_connect_status
          }
      end

    %{
      id: lot.id,
      number: lot.number,
      floor: lot.floor,
      is_rentable: lot.is_rentable,
      rental_price_per_hour_cents: lot.rental_price_per_hour_cents,
      rental_price_per_month_cents: lot.rental_price_per_month_cents,
      rental_description: lot.rental_description,
      building_id: lot.building_id,
      owner: owner
    }
  end

  defp payment_json(payment) do
    res = payment.reservation
    lot = res && res.lot

    %{
      id: payment.id,
      reservation_id: payment.reservation_id,
      amount_cents: payment.amount_cents,
      commission_cents: payment.commission_cents,
      currency: payment.currency,
      status: payment.status,
      reservation:
        if(res,
          do: %{
            id: res.id,
            starts_at: res.starts_at,
            ends_at: res.ends_at,
            status: res.status,
            lot:
              if(lot,
                do: %{id: lot.id, number: lot.number, floor: lot.floor},
                else: nil
              )
          },
          else: nil
        ),
      inserted_at: payment.inserted_at
    }
  end

  defp errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
