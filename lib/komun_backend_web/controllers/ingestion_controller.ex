defmodule KomunBackendWeb.IngestionController do
  @moduledoc """
  Endpoint d'ingestion intelligente pour l'admin.

  POST /api/v1/buildings/:building_id/ingestions/files
  Body : multipart `files[]` (ou `files`).

  Pour chaque fichier :

    * `.eml`              → parse → email → route_email
    * `.pdf` / image      → save_upload + email synthétique → route_email
    * autre               → status: "unsupported" (skip non bloquant)

  Côté AI, c'est `IncidentRouter.route` qui décide append vs create,
  puis `IncidentSummarizer.regenerate(:all)` regenère titre + description
  + micro_summary (déclenché en aval par `Incidents.add_comment`).
  """

  use KomunBackendWeb, :controller

  require Logger

  alias KomunBackend.{Buildings, InboundEmails}
  alias KomunBackend.InboundEmails.EmlParser
  alias KomunBackend.AI.EmailExtractor
  alias KomunBackend.Auth.Guardian

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]
  @eml_exts ~w(.eml)
  @pdf_exts ~w(.pdf)
  @image_exts ~w(.jpg .jpeg .png .gif .webp .heic)

  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    cond do
      not privileged?(user, building_id) ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Réservé au syndic et au conseil syndical"})

      true ->
        case InboundEmails.system_author() do
          {:error, :no_system_user} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Aucun utilisateur système configuré"})

          {:ok, author} ->
            files = collect_files(params)

            if files == [] do
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Au moins un fichier requis"})
            else
              results = Enum.map(files, &ingest_one(building_id, author.id, &1))
              json(conn, %{ingested: results})
            end
        end
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
        ingest_document(building_id, author_id, upload)

      true ->
        %{filename: filename, status: "unsupported", error: "Format non géré : " <> ext}
    end
  rescue
    e ->
      Logger.error("[ingestion] " <> inspect(e) <> " on " <> upload.filename)
      %{filename: upload.filename, status: "error", error: Exception.message(e)}
  end

  defp ingest_eml(building_id, author_id, %Plug.Upload{filename: filename, path: path}) do
    raw = File.read!(path)
    email = EmlParser.parse(raw)

    if is_nil(email.from) or email.from == "" do
      %{filename: filename, status: "error", error: "Email illisible (champ `from` introuvable)"}
    else
      do_route(filename, building_id, author_id, email)
    end
  end

  defp ingest_document(building_id, author_id, %Plug.Upload{filename: filename, path: tmp_path} = upload) do
    ext = filename |> Path.extname() |> String.downcase()

    case save_upload(upload) do
      {:ok, relative_path} ->
        url = "/" <> relative_path

        # Pipeline IA — pdftotext / tesseract → Groq → from/subject/body.
        # Si l'IA n'a pas pu lire (pas de texte, Groq down…) on tombe en
        # fallback "Document importé" sans expéditeur, tout en gardant
        # le lien vers le fichier dans le body.
        email =
          case EmailExtractor.extract(tmp_path, ext) do
            {:ok, extracted} ->
              build_extracted_email(extracted, filename, url)

            {:error, reason} ->
              Logger.warning("[ingestion] EmailExtractor failed on #{filename}: #{inspect(reason)} — falling back")
              build_fallback_email(filename, url)
          end

        do_route(filename, building_id, author_id, email)

      {:error, reason} ->
        %{filename: filename, status: "error", error: "Échec sauvegarde : " <> inspect(reason)}
    end
  end

  # Email enrichi par Groq — on a from/subject/body issus du contenu
  # du fichier. On épingle le lien vers le fichier en fin de body pour
  # que l'admin puisse retomber dessus depuis la timeline.
  defp build_extracted_email(extracted, filename, url) do
    body =
      (extracted[:body] || "")
      |> String.trim()
      |> case do
        "" -> "(contenu vide)"
        b -> b
      end
      |> Kernel.<>("\n\n---\nPièce jointe : " <> filename <> " (" <> url <> ")")

    %{
      from: extracted[:from] || "",
      from_name: extracted[:from_name],
      to: extracted[:to],
      cc: nil,
      subject: extracted[:subject] || filename_to_subject(filename),
      body: body,
      received_at: extracted[:received_at] || DateTime.utc_now()
    }
  end

  defp build_fallback_email(filename, url) do
    %{
      from: "",
      from_name: nil,
      to: nil,
      cc: nil,
      subject: filename_to_subject(filename),
      body: "[Document importé]\n\nFichier : " <> filename <> "\nLien    : " <> url,
      received_at: DateTime.utc_now()
    }
  end

  defp do_route(filename, building_id, author_id, email) do
    case InboundEmails.ingest_email(building_id, author_id, email) do
      {:ok, %{action: :create, incident_id: id}} ->
        %{filename: filename, status: "ok", action: "create", incident_id: id}

      {:error, reason} ->
        %{filename: filename, status: "error", error: inspect(reason)}
    end
  end

  # ── Files extraction ──────────────────────────────────────────────────

  defp collect_files(%{"files" => files}) when is_list(files) do
    Enum.filter(files, &match?(%Plug.Upload{}, &1))
  end

  defp collect_files(%{"files" => files}) when is_map(files) do
    files |> Map.values() |> Enum.filter(&match?(%Plug.Upload{}, &1))
  end

  defp collect_files(_), do: []

  # ── Auth ───────────────────────────────────────────────────────────────

  defp privileged?(user, building_id) do
    cond do
      is_nil(user) -> false
      user.role == :super_admin -> true
      user.role in @privileged_roles -> true
      Buildings.get_member_role(building_id, user.id) in @privileged_roles -> true
      true -> false
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
