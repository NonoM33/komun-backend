defmodule KomunBackendWeb.CommonResourceBookingController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, CommonResources}
  alias KomunBackend.CommonResources.{Resource, Booking}
  alias KomunBackend.Notifications.Jobs.NotifyCouncilOfBookingJob
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/common-resources/:resource_id/bookings
  # Calendrier d'une ressource — lecture pour tout membre du bâtiment.
  def index_for_resource(conn, %{"resource_id" => resource_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    resource = CommonResources.get_resource!(resource_id)

    with :ok <- authorize_member(conn, resource.building_id, user) do
      bookings = CommonResources.list_bookings_for_resource(resource_id, params)
      json(conn, %{data: Enum.map(bookings, &booking_json(&1, user))})
    end
  end

  # GET /api/v1/buildings/:building_id/bookings
  # Vue d'ensemble (utilisée notamment pour l'inbox conseil avec filtre
  # `?status=pending`). Tout membre peut lire — la PII des `reason` est
  # masquée pour les non-validateurs.
  def index_for_building(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_member(conn, building_id, user) do
      bookings = CommonResources.list_bookings_for_building(building_id, params)
      json(conn, %{data: Enum.map(bookings, &booking_json(&1, user))})
    end
  end

  # GET /api/v1/me/bookings
  def index_mine(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    if is_nil(user) do
      conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"}) |> halt()
    else
      bookings = CommonResources.list_bookings_for_user(user.id)
      json(conn, %{data: Enum.map(bookings, &booking_json(&1, user))})
    end
  end

  # GET /api/v1/bookings/:id
  def show(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    booking = CommonResources.get_booking!(id)
    resource = booking.common_resource

    with :ok <- authorize_member(conn, resource.building_id, user) do
      json(conn, %{data: booking_json(booking, user)})
    end
  end

  # POST /api/v1/common-resources/:resource_id/bookings
  def create(conn, %{"resource_id" => resource_id, "booking" => attrs}) do
    user = Guardian.Plug.current_resource(conn)
    resource = CommonResources.get_resource!(resource_id)

    with :ok <- authorize_member(conn, resource.building_id, user),
         {:ok, booking} <- CommonResources.create_booking(resource_id, user.id, attrs) do
      enqueue_council_notification(booking, resource)

      conn
      |> put_status(:created)
      |> json(%{data: booking_json(booking, user)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})
        |> halt()

      {:error, reason} when is_atom(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: Atom.to_string(reason)})
        |> halt()

      %Plug.Conn{} = halted ->
        halted
    end
  end

  # PATCH /api/v1/bookings/:id/approve
  def approve(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    booking = CommonResources.get_booking!(id)

    with :ok <- authorize_validator(conn, booking, user),
         {:ok, updated} <- CommonResources.approve_booking(booking, user.id) do
      json(conn, %{data: booking_json(reload(updated), user)})
    else
      {:error, :not_pending} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "La demande n'est plus en attente."})
        |> halt()

      %Plug.Conn{} = halted ->
        halted
    end
  end

  # PATCH /api/v1/bookings/:id/reject
  def reject(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    booking = CommonResources.get_booking!(id)
    reason = Map.get(params, "rejection_reason")

    with :ok <- authorize_validator(conn, booking, user),
         {:ok, updated} <- CommonResources.reject_booking(booking, user.id, reason) do
      json(conn, %{data: booking_json(reload(updated), user)})
    else
      {:error, :not_pending} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "La demande n'est plus en attente."})
        |> halt()

      %Plug.Conn{} = halted ->
        halted
    end
  end

  # DELETE /api/v1/bookings/:id  (annulation)
  def cancel(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    booking = CommonResources.get_booking!(id)
    resource = booking.common_resource
    is_admin = CommonResources.admin?(resource.building_id, user)
    is_owner = user && booking.requester_id == user.id

    cond do
      !is_owner and !is_admin ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seul le demandeur ou un admin peut annuler cette réservation."})
        |> halt()

      true ->
        case CommonResources.cancel_booking(booking) do
          {:ok, updated} ->
            json(conn, %{data: booking_json(reload(updated), user)})

          {:error, :already_started} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "La réservation a déjà commencé, impossible de l'annuler."})
            |> halt()
        end
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp reload(%Booking{id: id}), do: CommonResources.get_booking!(id)

  defp enqueue_council_notification(%Booking{id: booking_id}, %Resource{building_id: building_id}) do
    %{"booking_id" => booking_id, "building_id" => building_id}
    |> NotifyCouncilOfBookingJob.new()
    |> Oban.insert()
  end

  defp booking_json(%Booking{} = b, viewer) do
    can_see_pii = can_see_pii?(b, viewer)

    %{
      id: b.id,
      common_resource_id: b.common_resource_id,
      common_resource:
        case b.common_resource do
          %Resource{} = r -> %{id: r.id, name: r.name, kind: r.kind}
          _ -> nil
        end,
      requester_id: b.requester_id,
      requester:
        case b.requester do
          %{first_name: fn_, last_name: ln} -> %{first_name: fn_, last_name: ln}
          _ -> nil
        end,
      starts_at: b.starts_at,
      ends_at: b.ends_at,
      reason: if(can_see_pii, do: b.reason, else: nil),
      status: b.status,
      validated_by_id: b.validated_by_id,
      validated_at: b.validated_at,
      rejection_reason: b.rejection_reason,
      inserted_at: b.inserted_at,
      updated_at: b.updated_at
    }
  end

  # Le motif (`reason`) peut contenir des infos personnelles
  # (« Déménagement de M. Untel, lot 14 »). On le rend uniquement à :
  #   - super_admin
  #   - le demandeur lui-même
  #   - les validateurs (syndic + conseil syndical du bâtiment)
  defp can_see_pii?(_, nil), do: false
  defp can_see_pii?(_, %{role: :super_admin}), do: true
  defp can_see_pii?(%Booking{requester_id: rid}, %{id: rid}), do: true

  defp can_see_pii?(%Booking{common_resource: %Resource{building_id: bid}}, viewer) do
    CommonResources.can_validate?(bid, viewer)
  end

  defp can_see_pii?(_, _), do: false

  # ------------------------------------------------------------------
  # Authz
  # ------------------------------------------------------------------

  defp authorize_member(conn, building_id, user) do
    cond do
      is_nil(user) ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"}) |> halt()

      user.role == :super_admin ->
        :ok

      Buildings.member?(building_id, user.id) ->
        :ok

      true ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp authorize_validator(conn, %Booking{common_resource: %Resource{building_id: bid}}, user) do
    cond do
      is_nil(user) ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"}) |> halt()

      CommonResources.can_validate?(bid, user) ->
        :ok

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seuls le syndic et le conseil syndical peuvent valider une réservation."})
        |> halt()
    end
  end

  defp format_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
