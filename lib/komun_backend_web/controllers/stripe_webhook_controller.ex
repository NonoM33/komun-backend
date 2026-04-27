defmodule KomunBackendWeb.StripeWebhookController do
  @moduledoc """
  Endpoint webhook Stripe : `POST /api/v1/webhooks/stripe`.

  Vérifie la signature `Stripe-Signature` (HMAC SHA256 du payload brut
  avec `STRIPE_WEBHOOK_SECRET`) puis route les events vers les handlers
  Payments / StripeConnect.

  Les body raw doivent passer par `KomunBackendWeb.Plugs.RawBody` ou
  équivalent — le check de signature exige le payload byte-pour-byte
  identique à ce que Stripe a envoyé. À configurer côté `endpoint.ex`
  pour ce path précis (à faire en prod, peu critique en stg).
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.{Accounts, Payments, StripeConnect}

  def handle(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""
    signature = get_req_header(conn, "stripe-signature") |> List.first()

    with {:ok, event} <- verify_event(raw_body, signature) do
      route_event(event)
      json(conn, %{received: true})
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Webhook verification failed", detail: to_string(reason)})
    end
  end

  defp route_event(%{"type" => "payment_intent.succeeded", "data" => %{"object" => intent}}) do
    Payments.mark_succeeded(intent["id"], get_in(intent, ["latest_charge"]))
  end

  defp route_event(%{
         "type" => "payment_intent.payment_failed",
         "data" => %{"object" => intent}
       }) do
    reason = get_in(intent, ["last_payment_error", "message"]) || "unknown"
    Payments.mark_failed(intent["id"], reason)
  end

  defp route_event(%{"type" => "account.updated", "data" => %{"object" => account}}) do
    case Accounts.get_user_by_stripe_account(account["id"]) do
      nil -> :ok
      user -> StripeConnect.refresh_status(user)
    end
  end

  defp route_event(_), do: :ok

  # Signature : Stripe envoie un header `Stripe-Signature` du type
  # `t=1700000000,v1=hex...`. On recompute HMAC SHA256 du payload pour
  # vérifier que personne d'autre n'a forgé le webhook.
  defp verify_event(_raw, nil), do: {:error, :missing_signature}

  defp verify_event(raw_body, header) do
    case secret() do
      nil ->
        # Pas de secret configuré → en prod = 400. En dev/test on
        # accepte sans signature pour pouvoir tester localement.
        if Application.get_env(:komun_backend, :env, :prod) in [:dev, :test] do
          {:ok, Jason.decode!(raw_body)}
        else
          {:error, :webhook_secret_not_configured}
        end

      secret ->
        verify_signature(raw_body, header, secret)
    end
  end

  defp verify_signature(raw_body, header, secret) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.into(%{}, fn [k, v] -> {k, v} end)

    timestamp = parts["t"]
    sig = parts["v1"]

    if is_nil(timestamp) or is_nil(sig) do
      {:error, :malformed_signature}
    else
      payload = "#{timestamp}.#{raw_body}"
      expected = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(expected, sig) do
        case Jason.decode(raw_body) do
          {:ok, event} -> {:ok, event}
          _ -> {:error, :invalid_json}
        end
      else
        {:error, :signature_mismatch}
      end
    end
  end

  defp secret, do: System.get_env("STRIPE_WEBHOOK_SECRET")
end
