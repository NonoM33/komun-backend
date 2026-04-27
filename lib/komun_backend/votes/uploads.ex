defmodule KomunBackend.Votes.Uploads do
  @moduledoc """
  Local-disk persistence for vote attachments.

  Mirrors the pattern used in `KomunBackendWeb.DevisController.save_upload/1`
  — files are copied to `priv/static/uploads/votes/...` and we return a
  relative `file_url` plus filesystem metadata. We do NOT use ExAws/S3 yet
  because the rest of the app still relies on local disk; an S3 migration
  is a follow-up that should cover documents, devis and votes in one go.
  """

  require Logger

  @subdir "votes"

  @doc """
  Persists a `%Plug.Upload{}` and returns the metadata map expected by
  `KomunBackend.Votes.VoteAttachment.changeset/2` (or by VoteOption when
  the upload backs an option).

  Returns `{:ok, attrs}` or `{:error, reason}`.
  """
  def save(%Plug.Upload{filename: filename, path: tmp_path, content_type: ctype}) do
    ext = Path.extname(filename || "")
    unique_name = "#{System.unique_integer([:positive, :monotonic])}#{ext}"
    dest_dir = Application.app_dir(:komun_backend, "priv/static/uploads/#{@subdir}")
    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, unique_name)

    case File.cp(tmp_path, dest_path) do
      :ok ->
        {:ok,
         %{
           file_url: "uploads/#{@subdir}/#{unique_name}",
           filename: filename,
           file_size_bytes: file_size(tmp_path),
           mime_type: ctype
         }}

      {:error, reason} = err ->
        Logger.error("Vote upload copy failed: #{inspect(reason)}")
        err
    end
  end

  def save(_), do: {:error, :not_an_upload}

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end
end
