defmodule KomunBackendWeb.WebhookController do
  @moduledoc """
  Endpoints de webhooks externes (Resend principalement).

  ## POST /api/v1/webhooks/resend/inbound

  Reçoit les emails entrants envoyés à un alias Resend Inbound. **Cet
  endpoint est un pur relais** : il vérifie la signature et transfère le
  payload Resend tel quel à une routine Claude Code distante (sur le
  compte admin) qui s'occupe de toute la logique métier (identifier le
  bâtiment, lister les dossiers, décider append vs create, choisir le
  type incident/doléance/diligence, écrire dans Komun via l'API).

  ### Auth — signature **Svix HMAC SHA-256**

  Resend envoie 3 headers :

    * `webhook-id`        — identifiant unique du webhook (anti-replay)
    * `webhook-timestamp` — timestamp Unix (rejeté si > 5 min de dérive)
    * `webhook-signature` — `v1,<base64>` (peut contenir plusieurs sigs
      séparées par des espaces — rotation de clé)

  Le payload signé est `<id>.<timestamp>.<raw_body>`. La clé est lue
  depuis `RESEND_WEBHOOK_SIGNING_SECRET` (format `whsec_<base64>` — le
  préfixe est strippé et le reste base64-décodé pour obtenir les
  octets bruts utilisés comme HMAC key).

  Resend ne supporte pas les headers d'auth custom — c'est pour ça
  qu'on vérifie la signature plutôt qu'un Bearer.

  ### Format Resend (cf. https://resend.com/docs/inbound)

  ```json
  {
    "from": {"email": "voisin@gmail.com", "name": "Pascale"},
    "to": [{"email": "unisson@inbound.komun.app", "name": ""}],
    "subject": "Panne ascenseur",
    "text": "Bonjour, l'ascenseur ne marche plus...",
    "html": "<p>Bonjour...</p>",
    "date": "2026-04-28T10:00:00Z",
    "attachments": [
      {"filename": "photo.jpg", "content_type": "image/jpeg", "content": "<base64>"}
    ]
  }
  ```

  ### Forward vers la routine Claude

  Le payload Resend est passé tel quel à
  `KomunBackend.AI.IngestionDispatcher.dispatch_async/1`, qui POST sur :

    * `KOMUN_INGEST_TRIGGER_URL`   — URL HTTPS de la routine
    * `KOMUN_INGEST_TRIGGER_TOKEN` — bearer token attendu par le trigger

  Si l'une des deux env vars est absente, le dispatch est un no-op (on
  log et on renvoie 200 quand même côté Resend pour éviter ses retries
  en boucle pendant qu'on configure).
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.AI.IngestionDispatcher

  require Logger

  def resend_inbound(conn, params) do
    case verify_signature(conn) do
      :ok ->
        IngestionDispatcher.dispatch_async(params)
        json(conn, %{forwarded: true})

      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  # ── Auth (Svix HMAC) ────────────────────────────────────────────────────

  # Tolerance window for the timestamp anti-replay check (5 minutes,
  # matches the Svix recommendation).
  @max_timestamp_drift_s 5 * 60

  defp verify_signature(conn) do
    case signing_secret() do
      nil ->
        Logger.error("[resend-inbound] RESEND_WEBHOOK_SIGNING_SECRET not configured")
        {:error, :unauthorized}

      secret ->
        do_verify_signature(conn, secret)
    end
  end

  defp do_verify_signature(conn, secret) do
    raw_body = conn.assigns[:raw_body] || ""
    id_hdr = get_req_header(conn, "webhook-id") |> List.first()
    ts_hdr = get_req_header(conn, "webhook-timestamp") |> List.first()
    sig_hdr = get_req_header(conn, "webhook-signature") |> List.first()

    cond do
      raw_body == "" ->
        Logger.warning("[resend-inbound] missing raw body — endpoint plug not wired?")
        {:error, :unauthorized}

      is_nil(id_hdr) or is_nil(ts_hdr) or is_nil(sig_hdr) ->
        {:error, :unauthorized}

      not fresh_timestamp?(ts_hdr) ->
        Logger.warning("[resend-inbound] timestamp drift > #{@max_timestamp_drift_s}s")
        {:error, :unauthorized}

      true ->
        case decode_signing_secret(secret) do
          {:ok, secret_bytes} ->
            if signature_matches?(secret_bytes, id_hdr, ts_hdr, raw_body, sig_hdr) do
              :ok
            else
              Logger.warning("[resend-inbound] signature mismatch")
              {:error, :unauthorized}
            end

          :error ->
            Logger.error("[resend-inbound] malformed RESEND_WEBHOOK_SIGNING_SECRET")
            {:error, :unauthorized}
        end
    end
  end

  defp signing_secret, do: System.get_env("RESEND_WEBHOOK_SIGNING_SECRET")

  defp decode_signing_secret("whsec_" <> b64), do: Base.decode64(b64)
  defp decode_signing_secret(_), do: :error

  defp fresh_timestamp?(ts) do
    case Integer.parse(ts) do
      {n, _} -> abs(System.system_time(:second) - n) <= @max_timestamp_drift_s
      _ -> false
    end
  end

  # `webhook-signature` header may carry several entries separated by
  # spaces (key rotation, multi-version support). Each entry has the
  # form `<version>,<base64 signature>`. We only accept v1.
  defp signature_matches?(secret_bytes, id, ts, body, sig_header) do
    expected =
      :crypto.mac(:hmac, :sha256, secret_bytes, "#{id}.#{ts}.#{body}")
      |> Base.encode64()

    sig_header
    |> String.split(" ", trim: true)
    |> Enum.any?(fn entry ->
      case String.split(entry, ",", parts: 2) do
        ["v1", sig] -> Plug.Crypto.secure_compare(expected, sig)
        _ -> false
      end
    end)
  end
end
