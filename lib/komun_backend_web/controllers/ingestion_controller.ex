defmodule KomunBackendWeb.IngestionController do
  @moduledoc """
  Endpoint d'ingestion intelligente pour l'admin.

  L'admin Komun (privileged role : super_admin / syndic / conseil
  syndical) uploade un batch de fichiers (`.eml`, PDF, images). Pour
  chaque fichier on fabrique un email normalisé, puis on le passe au
  router AI (`KomunBackend.AI.IncidentRouter`) qui décide :

    * `:append` → on ajoute un commentaire 📧 à un incident ouvert
      existant (le summarizer regenerera le résumé après).
    * `:create` → on crée un nouvel incident minimal + 1er commentaire
      (le summarizer regenerera titre + description + micro_summary).

  La réponse renvoie un tableau `ingested` détaillant ce qui a été fait
  pour chaque fichier (action + incident_id, ou erreur).
  """

  use KomunBackendWeb, :controller

  require Logger

  alias KomunBackend.{Buildings, InboundEmails}
  alias KomunBackend.InboundEmails.EmlParser
  alias KomunBackend.Auth.Guardian

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  @eml_exts ~w(.eml)
  @pdf_exts ~w(.pdf)
  @image_exts ~w(.jpg .jpeg .png .gif .webp .heic)

  # POST /api/v1/buildings/:building_id/ingestions/files
  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user),
         {:ok, author} <- InboundEmails.system_author(),
         files when is_list(files) and files != [] <- collect_files(params) do
      results = Enum.map(files, &ingest_one(building_id, author.id, &1))

      json(conn, %{ingested: results})
    else
      [] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Au moins un fichier requis"})

      {:error, :no_system_user} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Aucun utilisateur système configuré"})

      _other ->
        # `authorize_privileged` halts the conn already on forbidden ;
        # this branch handles `nil` (files key missing).
        if conn.halted, do: conn, else: conn |> put_status(:unprocessable_entity) |> json(%{error: "Format invalide"})
    end
  end

  # ── Per-file ingestion ────────────────────────────────────────────────

  defp ingest_one(building_id, author_id, %Plug.Upload{} = upload) do
    filename = upload.filename
    ext = filename |> Path.extname() |> String.downcase()

    cond do
      ext in @eml_exts ->
        ingest_eml(building_id, author_id, upload)

      ext in @pdf_exts or ext in @image_exts ->
        ingest_document(building_id, author_id, upload, ext)

      true ->
        %{filename: filename, status: "unsupported", error: "Format non géré : #{ext}"}
    end
  rescue
    e ->
      Logger.error("[ingestion] #{inspect(e)} on #{upload.filename}")
      %{filename: upload.filename, status: "error", error: Exception.message(e)}
  end

  defp ingest_eml(building_id, author_id, %Plug.Upload{filename: filename, path: path}) do
    raw = File.read!(path)
    email = EmlParser.parse(raw)

    cond do
      is_nil(email.from) or email.from == "" ->
        %{filename: filename, status: "error", error: "Email illisible (champ `from` introuvable)"}

      true ->
        do_route(filename, building_id, author_id, email)
    end
  end

  defp ingest_document(building_id, author_id, %Plug.Upload{} = upload, _ext) do
    case save_upload(upload) do
      {:ok, relative_path} ->
        url = "/" <> relative_path

        email = %{
          from: "ingestion@komun.app",
          from_name: "Import manuel",
          to: nil,
          cc: nil,
          subject: filename_to_subject(upload.filename),
          body: """
          [Document importé manuellement]

          Fichier : #{upload.filename}
          Lien    : #{url}
          """,
          received_at: DateTime.utc_now()
        }

        do_route(upload.filename, building_id, author_id, email)

      {:error, reason} ->
        %{filename: upload.filename, status: "error", error: "Échec sauvegarde : #{reason}"}
    end
  end

  defp do_route(filename, building_id, author_id, email) do
    case InboundEmails.route_email(building_id, author_id, email) do
      {:ok, %{action: :append, incident_id: id, comment_id: cid}} ->
        %{filename: filename, status: "ok", action: "append", incident_id: id, comment_id: cid}

      {:ok, %{action: :create, incident_id: id}} ->
        %{filename: filename, status: "ok", action: "create", incident_id: id}

      {:error, reason} ->
        %{filename: filename, status: "error", error: inspect(reason)}
    end
  end

  # ── File collection ────────────────────────────────────────────────────

  # Phoenix can present `files` as a list (`files[]`) or a map indexed
  # by string keys. Tolerate both shapes.
  defp collect_files(%{"files" => files}) when is_list(files), do: Enum.filter(files, &match?(%Plug.Upload{}, &1))
  defp collect_files(%{"files" => files}) when is_map(files), do: files |> Map.values() |> Enum.filter(&match?(%Plug.Upload{}, &1))
  defp collect_files(_), do: []

  # ── Auth ───────────────────────────────────────────────────────────────

  defp authorize_privileged(conn, building_id, user) do
    cond do
      user.role == :super_admin -> :ok
      user.role in @privileged_roles -> :ok
      Buildings.get_member_role(building_id, user.id) in @privileged_roles -> :ok
      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Réservé au syndic et au conseil syndical"})
        |> halt()
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp save_upload(%Plug.Upload{filename: filename, path: tmp_path}) do
    ext = Path.extname(filename)
    unique_name = "#{System.unique_integer([:positive, :monotonic])}#{ext}"
    dest_dir = Application.app_dir(:komun_backend, "priv/static/uploads/ingestions")
    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, unique_name)

    case File.cp(tmp_path, dest_path) do
      :ok -> {:ok, "uploads/ingestions/#{unique_name}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp filename_to_subject(filename) do
    base = Path.basename(filename, Path.extname(filename))

    base
    |> String.replace(~r/[_\-]+/, " ")
    |> String.trim()
    |> case do
      "" -> "Document importé"
      s -> s
    end
  end
end
