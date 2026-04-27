defmodule KomunBackend.Incidents.LocalStorage do
  @moduledoc """
  Persistance disque des pièces jointes d'incidents + policy partagée
  (whitelist mime, borne taille, déduction du `kind`).

  Tous les fichiers atterrissent sous
  `priv/static/uploads/incidents/:incident_id/<unique>.<ext>` — un dossier
  par incident pour qu'un `rm -rf` ciblé reste sûr (purge isolée). Les
  chemins relatifs renvoyés sont préfixés par `/` pour être servis tels
  quels par `Plug.Static`.

  Deux chemins d'entrée pour la persistance :

    * `save_upload/2` — pour les `%Plug.Upload{}` (formulaire HTTP).
    * `save_bytes/3`  — pour des bytes déjà en mémoire (typiquement une
      pièce jointe extraite d'un `.eml` via `EmlParser.extract_attachments/1`).

  La policy mime / taille est exposée via `allowed_mime_types/0`,
  `max_upload_bytes/0` et `photo_mime_types/0` pour qu'`IncidentController`
  et le pipeline d'ingestion d'emails appliquent strictement les mêmes
  règles.
  """

  alias Plug.Upload

  @max_upload_bytes 15 * 1024 * 1024
  @allowed_mime_types ~w(application/pdf image/jpeg image/png image/heic image/webp)
  @photo_mime_types ~w(image/jpeg image/png image/heic image/webp)

  @type ok ::
          {:ok, %{relative_path: String.t(), absolute_path: String.t(), size: non_neg_integer()}}
  @type err :: {:error, term()}

  def max_upload_bytes, do: @max_upload_bytes
  def allowed_mime_types, do: @allowed_mime_types
  def photo_mime_types, do: @photo_mime_types

  @doc """
  Si le client envoie un `kind` valide on le respecte. Sinon on déduit
  depuis le mime — image/* → photo, le reste → document.
  """
  def infer_kind(kind, _mime) when kind in ["photo", "document"], do: kind

  def infer_kind(_, mime) when is_binary(mime) do
    if mime in @photo_mime_types, do: "photo", else: "document"
  end

  def infer_kind(_, _), do: "document"

  @spec save_upload(Upload.t(), binary()) :: ok | err
  def save_upload(%Upload{filename: filename, path: tmp_path}, incident_id) do
    with {:ok, dest} <- prepare_destination(filename, incident_id),
         :ok <- File.cp(tmp_path, dest.absolute_path),
         {:ok, %{size: size}} <- File.stat(dest.absolute_path) do
      {:ok, Map.put(dest, :size, size)}
    end
  end

  @spec save_bytes(binary(), String.t(), binary()) :: ok | err
  def save_bytes(bytes, filename, incident_id) when is_binary(bytes) do
    with {:ok, dest} <- prepare_destination(filename, incident_id),
         :ok <- File.write(dest.absolute_path, bytes) do
      {:ok, Map.put(dest, :size, byte_size(bytes))}
    end
  end

  defp prepare_destination(filename, incident_id) do
    ext = filename |> Path.extname() |> safe_ext()
    unique_name = "#{System.unique_integer([:positive, :monotonic])}#{ext}"

    dest_dir =
      Application.app_dir(
        :komun_backend,
        "priv/static/uploads/incidents/#{incident_id}"
      )

    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, unique_name)

    {:ok,
     %{
       relative_path: "uploads/incidents/#{incident_id}/#{unique_name}",
       absolute_path: dest_path
     }}
  end

  # Si l'extension est inhabituelle (chars exotiques, vide…), on la jette
  # pour ne pas se retrouver avec un nom de fichier piégé sur disque. Le
  # `mime_type` reste, lui, fiable côté DB.
  defp safe_ext("." <> rest = ext) do
    if String.match?(rest, ~r/^[A-Za-z0-9]{1,8}$/), do: ext, else: ""
  end

  defp safe_ext(_), do: ""
end
