defmodule KomunBackend.StripeConnect do
  @moduledoc """
  Onboarding et gestion des comptes Stripe Connect Express des
  copropriétaires qui souhaitent louer leur place de parking.

  Workflow :
  1. `start_onboarding(user)` → crée un compte Express si pas déjà fait,
     puis génère un Account Link et retourne son URL. Le proprio se rend
     sur la page hosted Stripe pour saisir ses infos (nom, IBAN, pièce
     d'identité…). Pas besoin de SIRET — Stripe accepte les particuliers.
  2. Une fois le KYC validé, Stripe redirige vers `return_url`.
  3. `refresh_status(user)` re-fetch le compte côté Stripe et met à jour
     `stripe_connect_status` localement (utilisé après le callback ou
     périodiquement par un job de réconciliation).
  """

  alias KomunBackend.Accounts.User
  alias KomunBackend.Repo
  alias KomunBackend.StripeApi

  @doc """
  Crée le compte Stripe Connect Express si l'user n'en a pas, puis génère
  l'URL d'onboarding hosted. `return_url` et `refresh_url` sont les pages
  vers lesquelles Stripe redirige (après validation / si l'user veut
  recommencer).
  """
  def start_onboarding(%User{} = user, return_url, refresh_url) do
    with {:ok, %User{stripe_connect_account_id: account_id} = user} <-
           ensure_account(user),
         {:ok, link} <-
           StripeApi.create_account_link(%{
             account: account_id,
             refresh_url: refresh_url,
             return_url: return_url,
             type: "account_onboarding"
           }) do
      {:ok, %{user: user, onboarding_url: link["url"], expires_at: link["expires_at"]}}
    end
  end

  @doc """
  Re-fetch le compte Stripe et synchronise `stripe_connect_status`. À
  appeler après le retour de l'onboarding (ou via webhook
  `account.updated`).
  """
  def refresh_status(%User{stripe_connect_account_id: nil} = user), do: {:ok, user}

  def refresh_status(%User{stripe_connect_account_id: account_id} = user) do
    case StripeApi.retrieve_account(account_id) do
      {:ok, account} ->
        status = derive_status(account)
        attrs = build_status_attrs(status, user.stripe_connect_onboarded_at)

        user
        |> User.changeset(attrs)
        |> Repo.update()

      {:error, _} = err ->
        err
    end
  end

  defp ensure_account(%User{stripe_connect_account_id: id} = user) when is_binary(id),
    do: {:ok, user}

  defp ensure_account(%User{} = user) do
    with {:ok, account} <- StripeApi.create_express_account(default_account_params(user)) do
      user
      |> User.changeset(%{
        stripe_connect_account_id: account["id"],
        stripe_connect_status: :pending
      })
      |> Repo.update()
    end
  end

  defp default_account_params(%User{} = user) do
    %{
      email: user.email,
      business_type: "individual",
      metadata: %{user_id: user.id}
    }
  end

  defp derive_status(%{"charges_enabled" => true, "payouts_enabled" => true}), do: :verified
  defp derive_status(%{"requirements" => %{"disabled_reason" => reason}}) when is_binary(reason),
    do: :rejected
  defp derive_status(_), do: :pending

  defp build_status_attrs(:verified, nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %{stripe_connect_status: :verified, stripe_connect_onboarded_at: now}
  end

  defp build_status_attrs(status, _), do: %{stripe_connect_status: status}
end
