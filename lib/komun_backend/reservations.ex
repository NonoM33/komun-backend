defmodule KomunBackend.Reservations do
  @moduledoc """
  Contexte des réservations de lots (places de recharge en V1, location
  payante en V2). Toute la logique métier passe par ce module — les
  controllers ne touchent JAMAIS au Repo directement.
  """

  import Ecto.Query

  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.Lot
  alias KomunBackend.Repo
  alias KomunBackend.Reservations.Reservation

  @doc """
  Liste les places de recharge actives d'un bâtiment (lots `:parking`
  flaggés `is_charging_spot`).
  """
  def list_charging_spots(building_id) do
    from(l in Lot,
      where:
        l.building_id == ^building_id and
          l.is_charging_spot == true,
      order_by: [asc: l.number]
    )
    |> Repo.all()
  end

  @doc """
  Liste les réservations confirmées d'un lot dans une fenêtre temporelle.
  Utilisé par le frontend pour afficher le calendrier des créneaux pris.
  """
  def list_reservations_for_lot(lot_id, %DateTime{} = from, %DateTime{} = until) do
    from(r in Reservation,
      where:
        r.lot_id == ^lot_id and
          r.status == :confirmed and
          r.ends_at > ^from and
          r.starts_at < ^until,
      order_by: [asc: r.starts_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc """
  Crée une réservation pour `user` sur `lot`. Vérifie que le user est
  bien membre actif du bâtiment du lot, sinon `{:error, :not_member}`.

  Le chevauchement sur le même lot est bloqué côté Postgres par la
  constraint EXCLUDE — l'erreur remonte sous forme de changeset error
  sur `:starts_at`.
  """
  def create_reservation(user_id, lot_id, attrs) when is_binary(user_id) and is_binary(lot_id) do
    with %Lot{} = lot <- Repo.get(Lot, lot_id),
         true <- Buildings.member?(lot.building_id, user_id) || {:error, :not_member} do
      attrs =
        attrs
        |> Map.put("user_id", user_id)
        |> Map.put("lot_id", lot_id)
        |> Map.put_new("building_id", lot.building_id)
        |> Map.put_new("kind", default_kind_for_lot(lot))

      %Reservation{}
      |> Reservation.changeset(attrs)
      |> Repo.insert()
    else
      nil -> {:error, :lot_not_found}
      {:error, _} = err -> err
      false -> {:error, :not_member}
    end
  end

  defp default_kind_for_lot(%Lot{is_charging_spot: true}), do: "charging"
  defp default_kind_for_lot(%Lot{}), do: "rental"

  @doc """
  Cancel d'une réservation par son propriétaire (ou un admin building).
  Soft delete : on passe `status` à `:cancelled`, on garde la ligne
  pour l'audit / facturation rétroactive en V2.
  """
  def cancel_reservation(reservation_id, user_id) do
    case Repo.get(Reservation, reservation_id) do
      nil ->
        {:error, :not_found}

      %Reservation{} = r ->
        if r.user_id == user_id || admin_for_building?(r.building_id, user_id) do
          do_cancel(r)
        else
          {:error, :forbidden}
        end
    end
  end

  # Annulation d'une rental → tente le refund automatique selon la
  # politique "100% si > grace_hours avant starts_at". Pour une charging,
  # rien à rembourser (gratuit).
  defp do_cancel(%Reservation{kind: :rental} = r) do
    with {:ok, updated} <-
           r |> Reservation.changeset(%{status: :cancelled}) |> Repo.update() do
      _ = KomunBackend.Payments.maybe_refund_for_cancel(updated)
      {:ok, updated}
    end
  end

  defp do_cancel(%Reservation{} = r) do
    r
    |> Reservation.changeset(%{status: :cancelled})
    |> Repo.update()
  end

  defp admin_for_building?(building_id, user_id) do
    Buildings.get_member_role(building_id, user_id) in [
      :president_cs,
      :membre_cs
    ]
  end

  @doc "Liste mes réservations à venir (toutes places confondues)."
  def list_upcoming_for_user(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(r in Reservation,
      where:
        r.user_id == ^user_id and
          r.status == :confirmed and
          r.ends_at > ^now,
      order_by: [asc: r.starts_at],
      preload: [:lot]
    )
    |> Repo.all()
  end
end
