defmodule KomunBackend.CommonResources do
  @moduledoc """
  Contexte des ressources communes réservables et de leurs réservations.

  ## Workflow

  - L'admin (super_admin / syndic_manager / syndic_staff) configure les
    ressources d'un bâtiment via `create_resource/2`, `update_resource/2`,
    `delete_resource/1`. Une ressource « Ascenseur » est seedée
    automatiquement à la création d'un bâtiment (cf.
    `Buildings.create_building/1`) avec un préavis de 48h.

  - Tout résident (membre actif du bâtiment) peut consulter les
    ressources actives via `list_resources/1` et déposer une demande
    de réservation via `create_booking/3`. Le respect du préavis et
    de la fenêtre horaire est vérifié ici.

  - N'importe quel membre du conseil syndical (`president_cs`,
    `membre_cs`) peut approuver (`approve_booking/2`) ou refuser
    (`reject_booking/3`) une demande en attente. Le syndic et le
    `super_admin` peuvent aussi.

  - Le demandeur peut annuler sa propre demande tant que `starts_at`
    n'est pas passé. Un admin peut annuler n'importe quelle demande.

  Le gating fin (qui peut faire quoi) est dans le controller via
  `authorize_*/3`. Le contexte ici suppose que l'appelant a déjà été
  vérifié comme étant au moins membre du bâtiment.
  """

  import Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Accounts.User
  alias KomunBackend.CommonResources.{Resource, Booking}

  @council_member_roles [:president_cs, :membre_cs]
  @syndic_user_roles [:super_admin, :syndic_manager, :syndic_staff]

  # ---------------------------------------------------------------------
  # Authz helpers (utilisés par les controllers — exposés pour réutilisation)
  # ---------------------------------------------------------------------

  @doc """
  Vrai si `user` peut configurer les ressources du bâtiment (CRUD admin).
  Réservé aux rôles « syndic / super_admin » — le conseil syndical
  valide les demandes mais ne configure pas les ressources elles-mêmes.
  """
  def admin?(_building_id, nil), do: false
  def admin?(_building_id, %User{role: :super_admin}), do: true

  def admin?(_building_id, %User{role: role}) when role in @syndic_user_roles do
    true
  end

  def admin?(_building_id, _user), do: false

  @doc """
  Vrai si `user` peut valider une réservation (approuver / refuser).
  N'importe quel membre du conseil syndical du bâtiment, plus le syndic
  et le super_admin.
  """
  def can_validate?(_building_id, nil), do: false
  def can_validate?(_building_id, %User{role: :super_admin}), do: true

  def can_validate?(_building_id, %User{role: role}) when role in @syndic_user_roles do
    true
  end

  def can_validate?(building_id, %User{} = user) do
    Buildings.get_member_role(building_id, user.id) in @council_member_roles
  end

  # ---------------------------------------------------------------------
  # Resource CRUD
  # ---------------------------------------------------------------------

  @doc """
  Liste les ressources actives d'un bâtiment (vue résident).
  Un résident voit uniquement les ressources `active: true` ; l'admin a
  son propre endpoint pour voir l'historique complet (`list_all_resources/1`).
  """
  def list_resources(building_id) do
    from(r in Resource,
      where: r.building_id == ^building_id and r.active == true,
      order_by: [asc: r.name]
    )
    |> Repo.all()
  end

  @doc "Liste toutes les ressources d'un bâtiment, actives ou non (vue admin)."
  def list_all_resources(building_id) do
    from(r in Resource,
      where: r.building_id == ^building_id,
      order_by: [asc: r.name]
    )
    |> Repo.all()
  end

  def get_resource!(id), do: Repo.get!(Resource, id)
  def get_resource(id), do: Repo.get(Resource, id)

  def create_resource(building_id, attrs) when is_binary(building_id) do
    attrs = Map.put(stringify(attrs), "building_id", building_id)

    %Resource{}
    |> Resource.create_changeset(attrs)
    |> Repo.insert()
  end

  def update_resource(%Resource{} = resource, attrs) do
    resource
    |> Resource.update_changeset(stringify(attrs))
    |> Repo.update()
  end

  def delete_resource(%Resource{} = resource) do
    Repo.delete(resource)
  end

  # ---------------------------------------------------------------------
  # Booking CRUD
  # ---------------------------------------------------------------------

  @doc """
  Liste les réservations d'une ressource. Par défaut renvoie tout l'historique
  (utile pour le calendrier côté résident — il voit les créneaux pris).
  """
  def list_bookings_for_resource(resource_id, filters \\ %{}) do
    from(b in Booking,
      where: b.common_resource_id == ^resource_id,
      order_by: [asc: b.starts_at],
      preload: [:requester, :validated_by]
    )
    |> apply_status_filter(filters)
    |> apply_window_filter(filters)
    |> Repo.all()
  end

  @doc """
  Liste toutes les réservations d'un bâtiment (toutes ressources confondues).
  Utilisé par l'inbox conseil pour voir les demandes en attente.
  """
  def list_bookings_for_building(building_id, filters \\ %{}) do
    from(b in Booking,
      join: r in Resource,
      on: r.id == b.common_resource_id,
      where: r.building_id == ^building_id,
      order_by: [desc: b.inserted_at],
      preload: [:requester, :validated_by, :common_resource]
    )
    |> apply_status_filter(filters)
    |> Repo.all()
  end

  @doc "Liste les réservations dont `user` est le demandeur."
  def list_bookings_for_user(user_id) do
    from(b in Booking,
      where: b.requester_id == ^user_id,
      order_by: [desc: b.inserted_at],
      preload: [:common_resource, :validated_by]
    )
    |> Repo.all()
  end

  def get_booking!(id) do
    Booking
    |> Repo.get!(id)
    |> Repo.preload([:common_resource, :requester, :validated_by])
  end

  @doc """
  Crée une demande de réservation. Vérifie :
    1. La ressource existe et est active.
    2. Le préavis minimum (`advance_notice_hours`) est respecté.
    3. La fenêtre horaire est dans `allowed_hours_*`.
    4. La durée n'excède pas `max_duration_hours`.
    5. Pour une ressource exclusive, pas de chevauchement avec une
       réservation `:pending` ou `:approved` existante.

  Renvoie `{:ok, booking}` ou `{:error, reason}` (atom ou changeset).
  """
  def create_booking(resource_id, requester_id, attrs)
      when is_binary(resource_id) and is_binary(requester_id) do
    with %Resource{active: true} = resource <- get_resource(resource_id),
         {:ok, starts_at, ends_at} <- parse_dates(attrs),
         :ok <- validate_advance_notice(resource, starts_at),
         :ok <- validate_hours_window(resource, starts_at, ends_at),
         :ok <- validate_duration(resource, starts_at, ends_at),
         :ok <- validate_no_overlap(resource, starts_at, ends_at, nil) do
      attrs =
        attrs
        |> stringify()
        |> Map.put("common_resource_id", resource_id)
        |> Map.put("requester_id", requester_id)

      %Booking{}
      |> Booking.create_changeset(attrs)
      |> Repo.insert()
    else
      nil -> {:error, :resource_not_found}
      %Resource{active: false} -> {:error, :resource_inactive}
      {:error, _} = err -> err
    end
  end

  @doc """
  Approuve une demande `:pending`. Met `status: :approved`,
  `validated_by_id`, `validated_at: now`. Pas de re-vérification de
  chevauchement (le conseil sait ce qu'il fait).
  """
  def approve_booking(%Booking{status: :pending} = booking, validator_id) do
    booking
    |> Booking.validation_changeset(%{
      status: :approved,
      validated_by_id: validator_id,
      validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  def approve_booking(%Booking{}, _), do: {:error, :not_pending}

  @doc """
  Rejette une demande `:pending`. La `reason` (motif du refus) est
  optionnelle mais fortement encouragée — c'est ce qui s'affiche au
  demandeur.
  """
  def reject_booking(booking, validator_id, reason \\ nil)

  def reject_booking(%Booking{status: :pending} = booking, validator_id, reason) do
    booking
    |> Booking.validation_changeset(%{
      status: :rejected,
      validated_by_id: validator_id,
      validated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      rejection_reason: reason
    })
    |> Repo.update()
  end

  def reject_booking(%Booking{}, _, _), do: {:error, :not_pending}

  @doc """
  Annulation par le demandeur (ou un admin). Refusée si la réservation
  est déjà passée — on garde la trace historique. Si elle est déjà
  `:cancelled` ou `:rejected`, no-op idempotent.
  """
  def cancel_booking(%Booking{status: :cancelled} = booking), do: {:ok, booking}
  def cancel_booking(%Booking{status: :rejected} = booking), do: {:ok, booking}

  def cancel_booking(%Booking{} = booking) do
    if DateTime.compare(booking.starts_at, DateTime.utc_now()) == :lt do
      {:error, :already_started}
    else
      booking
      |> Booking.cancellation_changeset()
      |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------
  # Council members lookup (used by the email job)
  # ---------------------------------------------------------------------

  @doc """
  Liste les utilisateurs à notifier lorsqu'une nouvelle demande arrive
  sur le bâtiment : membres actifs du conseil syndical + utilisateurs
  globaux syndic/super_admin associés au bâtiment.

  Utilisé par `Notifications.Jobs.NotifyCouncilOfBookingJob`.
  """
  def list_validators_for_building(building_id) do
    from(m in BuildingMember,
      join: u in User,
      on: u.id == m.user_id,
      where:
        m.building_id == ^building_id and
          m.is_active == true and
          (m.role in ^@council_member_roles or u.role in ^@syndic_user_roles),
      select: u,
      distinct: true
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------
  # Internal validation helpers
  # ---------------------------------------------------------------------

  defp parse_dates(attrs) do
    starts = Map.get(attrs, "starts_at") || Map.get(attrs, :starts_at)
    ends = Map.get(attrs, "ends_at") || Map.get(attrs, :ends_at)

    with {:ok, s} <- to_datetime(starts),
         {:ok, e} <- to_datetime(ends) do
      {:ok, s, e}
    else
      _ -> {:error, :invalid_dates}
    end
  end

  defp to_datetime(%DateTime{} = dt), do: {:ok, DateTime.truncate(dt, :second)}

  defp to_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> :error
    end
  end

  defp to_datetime(_), do: :error

  defp validate_advance_notice(%Resource{advance_notice_hours: hours}, %DateTime{} = starts_at) do
    min_start = DateTime.add(DateTime.utc_now(), hours * 3600, :second)

    if DateTime.compare(starts_at, min_start) == :lt do
      {:error, :advance_notice_not_met}
    else
      :ok
    end
  end

  defp validate_hours_window(%Resource{} = r, %DateTime{} = s, %DateTime{} = e) do
    # On compare en heures locales Europe/Paris — l'utilisateur réfléchit
    # en heure de chez lui, pas en UTC. Si la TZ DB n'est pas dispo, on
    # tombe sur UTC ; l'admin de la résidence peut alors paramétrer
    # `allowed_hours_*` en UTC.
    s_local = to_local(s)
    e_local = to_local(e)

    cond do
      s_local.hour < r.allowed_hours_start ->
        {:error, :outside_allowed_hours}

      e_local.hour > r.allowed_hours_end ->
        {:error, :outside_allowed_hours}

      e_local.hour == r.allowed_hours_end and e_local.minute > 0 ->
        {:error, :outside_allowed_hours}

      true ->
        :ok
    end
  end

  defp to_local(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, "Europe/Paris") do
      {:ok, local} -> local
      _ -> dt
    end
  end

  defp validate_duration(%Resource{max_duration_hours: max}, %DateTime{} = s, %DateTime{} = e) do
    diff_hours = DateTime.diff(e, s, :second) / 3600

    if diff_hours > max do
      {:error, :duration_exceeded}
    else
      :ok
    end
  end

  defp validate_no_overlap(%Resource{exclusive: false}, _, _, _), do: :ok

  defp validate_no_overlap(%Resource{exclusive: true, id: rid}, %DateTime{} = s, %DateTime{} = e, exclude_id) do
    # Chevauchement = (s < other.ends_at) AND (e > other.starts_at)
    # On ne considère que les bookings actifs (`pending` ou `approved`).
    base =
      from(b in Booking,
        where:
          b.common_resource_id == ^rid and
            b.status in [:pending, :approved] and
            b.starts_at < ^e and
            b.ends_at > ^s
      )

    base = if exclude_id, do: where(base, [b], b.id != ^exclude_id), else: base

    case Repo.aggregate(base, :count, :id) do
      0 -> :ok
      _ -> {:error, :overlap}
    end
  end

  defp apply_status_filter(q, %{"status" => s}) when is_binary(s) and s != "" do
    where(q, [b], b.status == ^s)
  end

  defp apply_status_filter(q, _), do: q

  defp apply_window_filter(q, %{"from" => from_str, "until" => until_str})
       when is_binary(from_str) and is_binary(until_str) do
    with {:ok, from_dt, _} <- DateTime.from_iso8601(from_str),
         {:ok, until_dt, _} <- DateTime.from_iso8601(until_str) do
      where(q, [b], b.ends_at > ^from_dt and b.starts_at < ^until_dt)
    else
      _ -> q
    end
  end

  defp apply_window_filter(q, _), do: q

  defp stringify(%{} = map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
