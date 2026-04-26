defmodule KomunBackendWeb.StripeConnectController do
  @moduledoc """
  Endpoints d'onboarding Stripe Connect Express pour les copropriétaires
  qui mettent leur place en location.

  Routes :
  - `POST /api/v1/me/stripe-connect/onboarding` → renvoie l'URL hosted
    Stripe pour démarrer (ou reprendre) le KYC.
  - `GET  /api/v1/me/stripe-connect/status` → état actuel du compte
    connecté (`:none | :pending | :verified | :rejected`).
  - `POST /api/v1/me/stripe-connect/refresh` → re-fetch côté Stripe et
    sync local. À appeler après le retour du flow d'onboarding.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.Auth.Guardian
  alias KomunBackend.StripeConnect

  def start_onboarding(conn, params) do
    user = Guardian.Plug.current_resource(conn)
    return_url = params["return_url"] || default_url("/parking/stripe-callback")
    refresh_url = params["refresh_url"] || default_url("/parking/list-my-spot")

    case StripeConnect.start_onboarding(user, return_url, refresh_url) do
      {:ok, %{onboarding_url: url, expires_at: expires_at}} ->
        json(conn, %{data: %{url: url, expires_at: expires_at}})

      {:error, %{type: :stripe_disabled}} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "Stripe non configuré",
          detail:
            "STRIPE_SECRET_KEY manquant côté serveur. La location payante n'est pas active."
        })

      {:error, %{message: message}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: message})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Impossible d'enregistrer le compte Stripe"})
    end
  end

  def status(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    json(conn, %{data: serialize(user)})
  end

  def refresh(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    case StripeConnect.refresh_status(user) do
      {:ok, fresh} -> json(conn, %{data: serialize(fresh)})
      {:error, %{type: :stripe_disabled}} = _err ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Stripe non configuré"})

      {:error, %{message: message}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: message})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Sync impossible"})
    end
  end

  defp serialize(user) do
    %{
      account_id: user.stripe_connect_account_id,
      status: user.stripe_connect_status,
      onboarded_at: user.stripe_connect_onboarded_at
    }
  end

  defp default_url(path) do
    base = System.get_env("APP_BASE_URL", "https://komun.app")
    base <> path
  end
end
