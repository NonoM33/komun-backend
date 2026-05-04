defmodule KomunBackendWeb.EventController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Events}
  alias KomunBackend.Events.{Event, EventComment, EventContribution}
  alias KomunBackend.Auth.Guardian

  @max_upload_bytes 10 * 1024 * 1024
  @photo_mime_types ~w(image/jpeg image/png image/heic image/webp)

  # ── Index / Show ─────────────────────────────────────────────────────────

  # GET /api/v1/buildings/:building_id/events
  def index(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      events = Events.list_events_for_building(building_id, params, user)

      json(conn, %{
        data: Enum.map(events, &event_json(&1, user))
      })
    end
  end

  # GET /api/v1/buildings/:building_id/events/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      event = Events.get_event!(id)

      cond do
        not event_visible_from_building?(event, building_id) ->
          not_found(conn)

        true ->
          json(conn, %{data: event_json(event, user)})
      end
    end
  end

  # ── Création / Édition / Annulation ─────────────────────────────────────

  # POST /api/v1/buildings/:building_id/events
  def create(conn, %{"building_id" => building_id, "event" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         residence_id when not is_nil(residence_id) <- Buildings.get_residence_id(building_id),
         :ok <- authorize_create(conn, residence_id, user),
         {:ok, event} <- Events.create_event(residence_id, user, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: event_json(event, user)})
    else
      nil -> not_found(conn)
      {:error, %Ecto.Changeset{} = cs} -> changeset_error(conn, cs)
      other -> other
    end
  end

  # PATCH/PUT /api/v1/buildings/:building_id/events/:id
  def update(conn, %{"building_id" => building_id, "id" => id, "event" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      event = Events.get_event!(id)

      cond do
        not event_visible_from_building?(event, building_id) ->
          not_found(conn)

        not Events.can_organize?(event.id, user) ->
          forbidden(conn, "Seul un organisateur peut modifier cet événement.")

        true ->
          case Events.update_event(event, attrs) do
            {:ok, updated} -> json(conn, %{data: event_json(updated, user)})
            {:error, cs} -> changeset_error(conn, cs)
          end
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/events/:id
  # → soft-cancel par défaut. Avec `?purge=true`, hard-delete réservé
  #   aux super_admin / syndic_manager (gating supplémentaire). Permet
  #   à un admin de retirer un event créé par erreur (doublon, etc.).
  def delete(conn, %{"building_id" => building_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    reason = Map.get(params, "reason", "Annulé par l'organisateur")
    purge? = Map.get(params, "purge") in [true, "true", "1"]

    with :ok <- authorize_building(conn, building_id) do
      event = Events.get_event!(id)

      cond do
        not event_visible_from_building?(event, building_id) ->
          not_found(conn)

        purge? and user.role not in [:super_admin, :syndic_manager] ->
          forbidden(conn,
            "Suppression définitive réservée aux super_admin / syndic_manager. Utilise l'annulation simple sinon."
          )

        purge? ->
          case Events.purge_event(event) do
            {:ok, _} -> send_resp(conn, :no_content, "")
            {:error, cs} -> changeset_error(conn, cs)
          end

        not Events.can_organize?(event.id, user) ->
          forbidden(conn, "Seul un organisateur peut annuler cet événement.")

        true ->
          case Events.cancel_event(event, reason) do
            {:ok, cancelled} -> json(conn, %{data: event_json(cancelled, user)})
            {:error, cs} -> changeset_error(conn, cs)
          end
      end
    end
  end

  # ── Cover photo upload ───────────────────────────────────────────────────

  # POST /api/v1/buildings/:building_id/events/:event_id/cover (multipart)
  def upload_cover(conn, %{"building_id" => building_id, "event_id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      event = Events.get_event!(id)

      cond do
        not event_visible_from_building?(event, building_id) ->
          not_found(conn)

        not Events.can_organize?(event.id, user) ->
          forbidden(conn, "Seul un organisateur peut changer la photo de couverture.")

        true ->
          do_upload_cover(conn, event, user, params)
      end
    end
  end

  defp do_upload_cover(conn, event, user, params) do
    upload = Map.get(params, "file")

    cond do
      not match?(%Plug.Upload{}, upload) ->
        unprocessable(conn, "Fichier requis (multipart \"file\")")

      upload.content_type not in @photo_mime_types ->
        unprocessable(conn, "Format refusé (JPEG, PNG, HEIC, WebP).")

      file_size(upload.path) > @max_upload_bytes ->
        unprocessable(conn, "Fichier trop volumineux (max 10 Mo).")

      true ->
        case save_cover_upload(upload, event.id) do
          {:ok, relative_path} ->
            url = "/" <> relative_path

            case Events.update_event(event, %{"cover_image_url" => url}) do
              {:ok, updated} -> json(conn, %{data: event_json(updated, user)})
              {:error, cs} -> changeset_error(conn, cs)
            end

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Échec de l'enregistrement : #{inspect(reason)}"})
        end
    end
  end

  defp save_cover_upload(%Plug.Upload{filename: filename, path: tmp_path}, event_id) do
    ext = Path.extname(filename)
    unique_name = "cover-#{System.unique_integer([:positive, :monotonic])}#{ext}"

    dest_dir = Application.app_dir(:komun_backend, "priv/static/uploads/events/#{event_id}")
    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, unique_name)

    case File.cp(tmp_path, dest_path) do
      :ok -> {:ok, "uploads/events/#{event_id}/#{unique_name}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  # ── Participations / RSVP ────────────────────────────────────────────────

  # POST /api/v1/buildings/:building_id/events/:event_id/participations
  def upsert_participation(conn, %{"building_id" => building_id, "event_id" => event_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "participation", %{})

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id),
         {:ok, _} <- Events.upsert_participation(event_id, user.id, attrs) do
      event = Events.get_event!(event_id)
      json(conn, %{data: event_json(event, user)})
    else
      {:error, %Ecto.Changeset{} = cs} -> changeset_error(conn, cs)
      other -> other
    end
  end

  # DELETE /api/v1/buildings/:building_id/events/:event_id/participations
  def delete_participation(conn, %{"building_id" => building_id, "event_id" => event_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id),
         {:ok, _} <- Events.delete_participation(event_id, user.id) do
      event = Events.get_event!(event_id)
      json(conn, %{data: event_json(event, user)})
    end
  end

  # ── Contributions (potluck) ──────────────────────────────────────────────

  # POST /api/v1/buildings/:building_id/events/:event_id/contributions
  def create_contribution(
        conn,
        %{"building_id" => building_id, "event_id" => event_id} = params
      ) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "contribution", %{})

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id),
         {:ok, _} <- Events.create_contribution(event_id, user.id, attrs) do
      event = Events.get_event!(event_id)
      json(conn, %{data: event_json(event, user)})
    else
      {:error, %Ecto.Changeset{} = cs} -> changeset_error(conn, cs)
      other -> other
    end
  end

  # PATCH /api/v1/buildings/:building_id/events/:event_id/contributions/:id
  def update_contribution(conn, %{
        "building_id" => building_id,
        "event_id" => event_id,
        "id" => id,
        "contribution" => attrs
      }) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      contribution = Events.get_contribution!(id)

      cond do
        contribution.event_id != event_id ->
          not_found(conn)

        not (contribution.created_by_id == user.id or Events.can_organize?(event_id, user)) ->
          forbidden(conn, "Vous ne pouvez modifier que les apports que vous avez ajoutés.")

        true ->
          case Events.update_contribution(contribution, attrs) do
            {:ok, _} ->
              event = Events.get_event!(event_id)
              json(conn, %{data: event_json(event, user)})

            {:error, cs} ->
              changeset_error(conn, cs)
          end
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/events/:event_id/contributions/:id
  def delete_contribution(conn, %{
        "building_id" => building_id,
        "event_id" => event_id,
        "id" => id
      }) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      contribution = Events.get_contribution!(id)

      cond do
        contribution.event_id != event_id ->
          not_found(conn)

        not (contribution.created_by_id == user.id or Events.can_organize?(event_id, user)) ->
          forbidden(conn, "Vous ne pouvez supprimer que les apports que vous avez ajoutés.")

        true ->
          {:ok, _} = Events.delete_contribution(contribution)
          event = Events.get_event!(event_id)
          json(conn, %{data: event_json(event, user)})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/events/:event_id/contributions/:id/claim
  #
  # Crée TOUJOURS un nouveau claim (plus d'upsert). Un voisin peut donc
  # avoir plusieurs claims sur la même rubrique avec des libellés
  # différents (« coca zero » + « coca cherry »).
  def claim_contribution(
        conn,
        %{"building_id" => building_id, "event_id" => event_id, "id" => id} = params
      ) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "claim", %{})

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      contribution = Events.get_contribution!(id)

      cond do
        contribution.event_id != event_id ->
          not_found(conn)

        true ->
          case Events.add_claim(id, user.id, attrs) do
            {:ok, _} ->
              event = Events.get_event!(event_id)
              json(conn, %{data: event_json(event, user)})

            {:error, cs} ->
              changeset_error(conn, cs)
          end
      end
    end
  end

  # PATCH /api/v1/buildings/:building_id/events/:event_id/contributions/:id/claims/:claim_id
  #
  # Met à jour un claim précis (qty, commentaire). L'utilisateur ne peut
  # toucher qu'à SES propres claims (les organisateurs aussi pour faire
  # le ménage si besoin).
  def update_claim(conn, %{
        "building_id" => building_id,
        "event_id" => event_id,
        "id" => contribution_id,
        "claim_id" => claim_id
      } = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "claim", %{})

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      claim = Events.get_claim!(claim_id)

      cond do
        claim.contribution_id != contribution_id ->
          not_found(conn)

        not (claim.user_id == user.id or Events.can_organize?(event_id, user)) ->
          forbidden(conn, "Vous ne pouvez modifier que vos propres apports.")

        true ->
          case Events.update_claim_by_id(claim_id, attrs) do
            {:ok, _} ->
              event = Events.get_event!(event_id)
              json(conn, %{data: event_json(event, user)})

            {:error, cs} ->
              changeset_error(conn, cs)
          end
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/events/:event_id/contributions/:id/claims/:claim_id
  def delete_claim(conn, %{
        "building_id" => building_id,
        "event_id" => event_id,
        "id" => contribution_id,
        "claim_id" => claim_id
      }) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      claim = Events.get_claim!(claim_id)

      cond do
        claim.contribution_id != contribution_id ->
          not_found(conn)

        not (claim.user_id == user.id or Events.can_organize?(event_id, user)) ->
          forbidden(conn, "Vous ne pouvez retirer que vos propres apports.")

        true ->
          {:ok, _} = Events.delete_claim_by_id(claim_id)
          event = Events.get_event!(event_id)
          json(conn, %{data: event_json(event, user)})
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/events/:event_id/contributions/:id/claim
  #
  # Endpoint legacy : supprime TOUS les claims du user courant sur cette
  # rubrique. Pratique pour un bouton « je ne ramène plus rien sur cette
  # rubrique » côté UI. Conservé pour la compat mobile.
  def unclaim_contribution(conn, %{
        "building_id" => building_id,
        "event_id" => event_id,
        "id" => id
      }) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      contribution = Events.get_contribution!(id)

      cond do
        contribution.event_id != event_id ->
          not_found(conn)

        true ->
          {:ok, _} = Events.delete_claim(id, user.id)
          event = Events.get_event!(event_id)
          json(conn, %{data: event_json(event, user)})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/events/:event_id/contributions/reorder
  # body : { "order": [contribution_id, …] }
  def reorder_contributions(conn, %{
        "building_id" => building_id,
        "event_id" => event_id
      } = params) do
    user = Guardian.Plug.current_resource(conn)
    order = Map.get(params, "order", [])

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      cond do
        not Events.can_organize?(event_id, user) ->
          forbidden(conn, "Seuls les organisateurs peuvent réordonner les apports.")

        not is_list(order) ->
          unprocessable(conn, "`order` doit être un tableau d'ids.")

        true ->
          {:ok, event} = Events.reorder_contributions(event_id, order)
          json(conn, %{data: event_json(event, user)})
      end
    end
  end

  # ── Commentaires ─────────────────────────────────────────────────────────

  # POST /api/v1/buildings/:building_id/events/:event_id/comments
  def create_comment(
        conn,
        %{"building_id" => building_id, "event_id" => event_id} = params
      ) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "comment", %{})

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id),
         {:ok, _} <- Events.add_comment(event_id, user.id, attrs) do
      event = Events.get_event!(event_id)
      json(conn, %{data: event_json(event, user)})
    else
      {:error, %Ecto.Changeset{} = cs} -> changeset_error(conn, cs)
      other -> other
    end
  end

  # DELETE /api/v1/buildings/:building_id/events/:event_id/comments/:id
  def delete_comment(conn, %{
        "building_id" => building_id,
        "event_id" => event_id,
        "id" => id
      }) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      comment = Events.get_comment!(id)

      cond do
        comment.event_id != event_id ->
          not_found(conn)

        not (comment.author_id == user.id or Events.can_organize?(event_id, user)) ->
          forbidden(conn, "Vous ne pouvez supprimer que vos propres commentaires.")

        true ->
          {:ok, _} = Events.delete_comment(comment)
          event = Events.get_event!(event_id)
          json(conn, %{data: event_json(event, user)})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/events/:event_id/blast
  # body : %{ "subject" => "...", "body" => "...", "confirm" => "TITLE-COPIED" }
  #
  # Manual email blast aux membres du scope. Réservé organisateurs.
  # Rate-limit hard 1/h côté contexte. Le frontend doit faire taper le
  # titre de l'event avant d'activer le bouton (confirmation forte) — le
  # backend vérifie aussi `confirm` non-vide pour défense en profondeur.
  def send_email_blast(conn, %{"building_id" => building_id, "event_id" => event_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      cond do
        not Events.can_organize?(event_id, user) ->
          forbidden(conn, "Seul un organisateur peut déclencher un email à tous les voisins.")

        params["confirm"] in [nil, ""] ->
          unprocessable(conn, "Confirmation manquante (champ `confirm` requis).")

        true ->
          ip = ip_from_conn(conn)

          case Events.send_email_blast(event_id, user,
                 ip: ip,
                 subject: params["subject"],
                 body: params["body"]
               ) do
            {:ok, _blast} ->
              event = Events.get_event!(event_id)
              json(conn, %{data: event_json(event, user)})

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{
                error:
                  "Un email a déjà été envoyé pour cet événement il y a moins d'une heure."
              })

            {:error, :forbidden} ->
              forbidden(conn, "Vous n'êtes pas organisateur.")

            {:error, :event_cancelled} ->
              unprocessable(conn, "L'événement est annulé — pas d'email envoyé.")

            {:error, :event_draft} ->
              unprocessable(conn, "Publiez l'événement avant de l'envoyer par email.")

            {:error, :not_found} ->
              not_found(conn)

            {:error, %Ecto.Changeset{} = cs} ->
              changeset_error(conn, cs)
          end
      end
    end
  end

  defp ip_from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [first | _] ->
        first |> String.split(",") |> List.first() |> String.trim()

      _ ->
        case conn.remote_ip do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          _ -> nil
        end
    end
  end

  # POST /api/v1/buildings/:building_id/events/:event_id/comments/:id/reactions
  # body : %{ "emoji" => "❤️" }
  def toggle_reaction(conn, %{
        "building_id" => building_id,
        "event_id" => event_id,
        "id" => id
      } = params) do
    user = Guardian.Plug.current_resource(conn)
    emoji = Map.get(params, "emoji")

    with :ok <- authorize_building(conn, building_id),
         :ok <- ensure_visible(conn, event_id, building_id) do
      comment = Events.get_comment!(id)

      cond do
        comment.event_id != event_id ->
          not_found(conn)

        not is_binary(emoji) or emoji == "" ->
          unprocessable(conn, "Emoji manquant")

        true ->
          case Events.toggle_reaction(comment, emoji, user.id) do
            {:ok, _} ->
              event = Events.get_event!(event_id)
              json(conn, %{data: event_json(event, user)})

            {:error, cs} ->
              changeset_error(conn, cs)
          end
      end
    end
  end

  # ── Helpers d'autorisation ───────────────────────────────────────────────

  defp authorize_building(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)

    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      :ok
    else
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp authorize_create(conn, residence_id, user) do
    if Events.can_create_event?(residence_id, user) do
      :ok
    else
      forbidden(conn, "Seuls le syndic et le conseil syndical peuvent créer un événement.")
    end
  end

  # Vérifie qu'un event est bien visible depuis le building demandé
  # (scope satisfait OU event résidence sans scope). Empêche d'accéder
  # à un event privé d'un autre bâtiment via URL directe.
  defp ensure_visible(conn, event_id, building_id) do
    event = Events.get_event!(event_id)

    if event_visible_from_building?(event, building_id) do
      :ok
    else
      conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()
    end
  end

  defp event_visible_from_building?(%Event{} = event, building_id) do
    residence_id = Buildings.get_residence_id(building_id)

    cond do
      is_nil(residence_id) -> false
      event.residence_id != residence_id -> false
      event.building_scopes == [] -> true
      true -> Enum.any?(event.building_scopes, &(&1.building_id == building_id))
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

  defp forbidden(conn, msg),
    do: conn |> put_status(:forbidden) |> json(%{error: msg}) |> halt()

  defp unprocessable(conn, msg),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: msg}) |> halt()

  defp changeset_error(conn, cs),
    do: conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── Sérialisation JSON ───────────────────────────────────────────────────

  defp event_json(%Event{} = event, viewer) do
    user_participation = find_user_participation(event, viewer)
    can_edit = viewer && Events.can_organize?(event.id, viewer)

    %{
      id: event.id,
      title: event.title,
      description: event.description,
      cover_image_url: event.cover_image_url,
      kind: event.kind,
      status: event.status,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      location_label: event.location_label,
      location_details: event.location_details,
      max_participants: event.max_participants,
      requires_registration: event.requires_registration,
      allow_plus_ones: event.allow_plus_ones,
      kid_friendly: event.kid_friendly,
      cancelled_at: event.cancelled_at,
      cancelled_reason: event.cancelled_reason,
      target_resident_types: event.target_resident_types || [],
      residence_id: event.residence_id,
      creator_id: event.creator_id,
      creator: maybe_user(event.creator),
      organizers: organizers_json(event.organizers),
      building_scopes: building_scopes_json(event.building_scopes),
      participations: participations_json(event.participations),
      participants_count: count_going(event.participations),
      total_attendees_with_plus_ones: count_with_plus_ones(event.participations),
      contributions: contributions_json(event.contributions),
      comments: comments_json(event.comments),
      user_participation: user_participation,
      can_edit: can_edit,
      email_blasts: blasts_json(event.email_blasts),
      last_manual_blast_at: last_manual_blast_at(event.email_blasts),
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  defp blasts_json(%Ecto.Association.NotLoaded{}), do: []

  defp blasts_json(list) when is_list(list) do
    list
    |> Enum.sort_by(& &1.sent_at, {:desc, DateTime})
    |> Enum.map(fn b ->
      %{
        id: b.id,
        kind: b.kind,
        recipient_count: b.recipient_count,
        subject: b.subject,
        triggered_by_id: b.triggered_by_id,
        sent_at: b.sent_at
      }
    end)
  end

  defp last_manual_blast_at(%Ecto.Association.NotLoaded{}), do: nil

  defp last_manual_blast_at(list) when is_list(list) do
    list
    |> Enum.filter(&(&1.kind == :manual_invite))
    |> Enum.map(& &1.sent_at)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp count_going(participations) do
    case participations do
      %Ecto.Association.NotLoaded{} -> 0
      list -> Enum.count(list, &(&1.status == :going))
    end
  end

  defp count_with_plus_ones(participations) do
    case participations do
      %Ecto.Association.NotLoaded{} ->
        0

      list ->
        list
        |> Enum.filter(&(&1.status == :going))
        |> Enum.reduce(0, fn p, acc -> acc + 1 + p.plus_ones_count end)
    end
  end

  defp find_user_participation(_event, nil), do: nil

  defp find_user_participation(%Event{participations: %Ecto.Association.NotLoaded{}}, _), do: nil

  defp find_user_participation(%Event{participations: list}, viewer) do
    case Enum.find(list, &(&1.user_id == viewer.id)) do
      nil -> nil
      p -> participation_json(p)
    end
  end

  defp organizers_json(%Ecto.Association.NotLoaded{}), do: []

  defp organizers_json(list) when is_list(list) do
    Enum.map(list, fn o ->
      %{
        user_id: o.user_id,
        role: o.role,
        user: maybe_user(o.user)
      }
    end)
  end

  defp building_scopes_json(%Ecto.Association.NotLoaded{}), do: []

  defp building_scopes_json(list) when is_list(list) do
    Enum.map(list, fn s ->
      %{
        building_id: s.building_id,
        building_name: if(s.building, do: s.building.name, else: nil)
      }
    end)
  end

  defp participations_json(%Ecto.Association.NotLoaded{}), do: []

  defp participations_json(list) when is_list(list) do
    Enum.map(list, &participation_json/1)
  end

  defp participation_json(p) do
    %{
      id: p.id,
      event_id: p.event_id,
      user_id: p.user_id,
      status: p.status,
      plus_ones_count: p.plus_ones_count,
      dietary_note: p.dietary_note,
      user: maybe_user(p.user),
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp contributions_json(%Ecto.Association.NotLoaded{}), do: []

  defp contributions_json(list) when is_list(list) do
    list
    # Tri par position (drag & drop côté UI), inserted_at en secondaire.
    |> Enum.sort_by(fn %EventContribution{} = c ->
      {c.position || 0, c.inserted_at}
    end)
    |> Enum.map(fn %EventContribution{} = c ->
      claims = claims_json(c.claims)
      claimed_qty = Enum.reduce(claims, 0, fn cl, acc -> acc + (cl.quantity || 0) end)

      %{
        id: c.id,
        event_id: c.event_id,
        title: c.title,
        category: c.category,
        needed_quantity: c.needed_quantity,
        claimed_quantity: claimed_qty,
        position: c.position,
        created_by_id: c.created_by_id,
        created_by: maybe_user(c.created_by),
        claims: claims,
        inserted_at: c.inserted_at
      }
    end)
  end

  defp claims_json(%Ecto.Association.NotLoaded{}), do: []

  defp claims_json(list) when is_list(list) do
    Enum.map(list, fn cl ->
      %{
        id: cl.id,
        contribution_id: cl.contribution_id,
        user_id: cl.user_id,
        quantity: cl.quantity,
        comment: cl.comment,
        user: maybe_user(cl.user)
      }
    end)
  end

  defp comments_json(%Ecto.Association.NotLoaded{}), do: []

  defp comments_json(list) when is_list(list) do
    list
    |> Enum.sort_by(& &1.inserted_at, {:asc, NaiveDateTime})
    |> Enum.map(fn %EventComment{} = c ->
      %{
        id: c.id,
        event_id: c.event_id,
        author_id: c.author_id,
        body: c.body,
        reactions: c.reactions || %{},
        author: maybe_user(c.author),
        inserted_at: c.inserted_at,
        updated_at: c.updated_at
      }
    end)
  end

  defp maybe_user(nil), do: nil
  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil

  defp maybe_user(u) do
    %{
      id: u.id,
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name,
      avatar_url: Map.get(u, :avatar_url)
    }
  end
end
