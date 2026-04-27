defmodule KomunBackend.AI.EmailExtractor do
  @moduledoc """
  Extrait `{from, from_name, to, subject, body, date}` d'un fichier
  uploadé qui n'est pas un `.eml` (PDF, image…).

  Pipeline :

    1. Texte brut extrait du fichier :
       * PDF      → `pdftotext <path> -` (binaire poppler-utils)
       * Image    → `tesseract <path> - -l fra` (binaire OCR)
       * autre    → contenu binaire ignoré, on tombe en fallback
    2. Texte envoyé à Groq qui retourne un JSON `{from_email, from_name,
       to, subject, body, date}` (champs nullables).
    3. Si l'extraction texte ou Groq échoue, on retourne `{:error, …}` —
       le caller décide d'utiliser un fallback (filename → subject,
       expéditeur "Inconnu").

  Conçu pour les PDFs Gmail-exportés (pleins de headers visuels comme
  "De :", "À :", "Sujet :", "Date :") et les photos d'avis de syndic.
  """

  require Logger

  alias KomunBackend.AI.Groq

  @system_prompt """
  Tu reçois le texte brut d'un document — souvent un email forwardé
  exporté en PDF, ou la photo d'un avis/courrier de syndic.

  Extrais en JSON STRICT (sans markdown, sans texte autour) :

    {
      "from_email": string | null,
      "from_name":  string | null,
      "to":         string | null,
      "subject":    string | null,
      "body":       string | null,
      "date":       string | null
    }

  Règles :
  - Si le doc est un email, le `body` est le contenu du message SANS
    les headers (De/À/Date/Sujet/Cc).
  - Si le doc n'est pas un email mais un courrier ou un avis, mets
    l'expéditeur (l'organisation qui l'envoie) en `from_name`, son
    email/contact en `from_email` si présent.
  - `subject` : titre, objet, ou résumé court (max 200 chars).
  - Champs introuvables → null (jamais inventer).
  - Réponds UNIQUEMENT avec le JSON.
  """

  @doc """
  Extrait les champs depuis un fichier sur disque + son extension.
  Renvoie `{:ok, %{from, from_name, to, subject, body, received_at}}`
  ou `{:error, reason}`.
  """
  @spec extract(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def extract(path, ext) when is_binary(path) and is_binary(ext) do
    with {:ok, text} <- file_to_text(path, ext),
         {:ok, parsed} <- ask_groq(text) do
      {:ok, normalize(parsed)}
    end
  end

  # ── File → text ──────────────────────────────────────────────────────

  defp file_to_text(path, ext) do
    cond do
      ext in [".pdf"] -> pdftotext(path)
      ext in [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic"] -> tesseract(path)
      true -> {:error, :unsupported_format}
    end
  end

  defp pdftotext(path) do
    case System.cmd("pdftotext", ["-layout", "-nopgbrk", path, "-"], stderr_to_stdout: true) do
      {output, 0} ->
        trimmed = String.trim(output)
        if trimmed == "", do: {:error, :empty_text}, else: {:ok, trimmed}

      {err, code} ->
        Logger.error("[email_extractor] pdftotext exit #{code}: #{err}")
        {:error, :pdftotext_failed}
    end
  rescue
    e ->
      Logger.error("[email_extractor] pdftotext crashed: #{inspect(e)}")
      {:error, :pdftotext_unavailable}
  end

  defp tesseract(path) do
    case System.cmd("tesseract", [path, "-", "-l", "fra"], stderr_to_stdout: true) do
      {output, 0} ->
        trimmed = String.trim(output)
        if trimmed == "", do: {:error, :empty_text}, else: {:ok, trimmed}

      {err, code} ->
        Logger.error("[email_extractor] tesseract exit #{code}: #{err}")
        {:error, :tesseract_failed}
    end
  rescue
    e ->
      Logger.error("[email_extractor] tesseract crashed: #{inspect(e)}")
      {:error, :tesseract_unavailable}
  end

  # ── Text → Groq → JSON ───────────────────────────────────────────────

  defp ask_groq(text) do
    user_text = String.slice(text, 0, 8000)

    messages = [
      %{role: :system, content: @system_prompt},
      %{role: :user, content: user_text}
    ]

    case Groq.complete(messages, temperature: 0.1, max_tokens: 1200) do
      {:ok, %{content: raw}} ->
        case extract_json(raw) do
          {:ok, _} = ok -> ok
          {:error, _} = err -> err
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_json(content) do
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, json} when is_map(json) -> {:ok, json}
      {:ok, _} -> {:error, :not_an_object}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  # ── Normalisation ────────────────────────────────────────────────────

  defp normalize(json) do
    %{
      from: nilify(json["from_email"]) |> to_string() |> String.downcase() |> String.trim(),
      from_name: nilify(json["from_name"]),
      to: nilify(json["to"]),
      subject: nilify(json["subject"]) || "",
      body: nilify(json["body"]) || "",
      received_at: nilify(json["date"])
    }
  end

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(s) when is_binary(s), do: String.trim(s)
  defp nilify(other), do: other
end
