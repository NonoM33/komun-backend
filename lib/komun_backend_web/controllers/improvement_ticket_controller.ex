defmodule KomunBackendWeb.ImprovementTicketController do
  use KomunBackendWeb, :controller

  alias KomunBackend.ImprovementTickets
  alias KomunBackend.ImprovementTickets.ImprovementTicket
  alias KomunBackend.Auth.Guardian

  # Captures d'écran : même bornes que les uploads incidents pour ne pas
  # multiplier les seuils. 15 Mo couvre largement une capture macOS Retina
  # plein écran en PNG.
  @max_upload_bytes 15 * 1024 * 1024
  @allowed_mime_types ~w(image/jpeg image/png image/heic image/webp)

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

  # POST /api/v1/improvement_tickets/:id/screenshots
  # Upload multipart "file" — l'auteur uniquement (les super_admin
  # peuvent voir les captures mais pas en ajouter).
  def upload_screenshot(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    case ImprovementTickets.get_ticket(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

      ticket ->
        cond do
          to_string(ticket.author_id) != to_string(user.id) ->
            conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()

          true ->
            do_upload(conn, ticket, params)
        end
    end
  end

  # DELETE /api/v1/improvement_tickets/:id/screenshots
  # Body JSON : { "url": "/uploads/improvement_tickets/:id/xxx.png" }
  def delete_screenshot(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    url = Map.get(params, "url")

    cond do
      not is_binary(url) or url == "" ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Champ \"url\" requis"})
        |> halt()

      true ->
        case ImprovementTickets.get_ticket(id) do
          nil ->
            conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

          ticket ->
            cond do
              to_string(ticket.author_id) != to_string(user.id) ->
                conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()

              true ->
                {:ok, updated} = ImprovementTickets.remove_screenshot(ticket, url)
                maybe_remove_file(url)
                json(conn, %{data: ticket_json(updated)})
            end
        end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp do_upload(conn, ticket, params) do
    upload = Map.get(params, "file")

    cond do
      not match?(%Plug.Upload{}, upload) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Fichier requis (multipart \"file\")"})
        |> halt()

      upload.content_type not in @allowed_mime_types ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Type de fichier refusé (autorisés : JPEG, PNG, HEIC, WebP)"})
        |> halt()

      file_size(upload.path) > @max_upload_bytes ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Fichier trop volumineux (max #{@max_upload_bytes} octets)"})
        |> halt()

      true ->
        case save_upload(upload, ticket.id) do
          {:ok, relative_path} ->
            url = "/" <> relative_path

            case ImprovementTickets.append_screenshot(ticket, url) do
              {:ok, updated} ->
                conn |> put_status(:created) |> json(%{data: ticket_json(updated)})

              {:error, cs} ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{errors: format_errors(cs)})
            end

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Échec de l'enregistrement : #{inspect(reason)}"})
        end
    end
  end

  defp save_upload(%Plug.Upload{filename: filename, path: tmp_path}, ticket_id) do
    ext = Path.extname(filename)
    unique_name = "#{System.unique_integer([:positive, :monotonic])}#{ext}"

    dest_dir =
      Application.app_dir(
        :komun_backend,
        "priv/static/uploads/improvement_tickets/#{ticket_id}"
      )

    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, unique_name)

    case File.cp(tmp_path, dest_path) do
      :ok -> {:ok, "uploads/improvement_tickets/#{ticket_id}/#{unique_name}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  # Best-effort : si on n'arrive pas à effacer le fichier sur disque
  # (déjà parti, chemin malformé…) on log et on continue. La ligne en
  # base est, elle, déjà à jour.
  defp maybe_remove_file("/" <> rel) do
    abs = Application.app_dir(:komun_backend, Path.join("priv/static", rel))

    case File.rm(abs) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("[improvement_tickets] could not remove #{abs}: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_remove_file(_), do: :ok

  @doc false
  def ticket_json(%ImprovementTicket{} = t) do
    %{
      id: t.id,
      kind: t.kind,
      title: t.title,
      description: t.description,
      status: t.status,
      admin_note: t.admin_note,
      screenshot_urls: t.screenshot_urls || [],
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
