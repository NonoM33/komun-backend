defmodule KomunBackend.StripeApi.Mock do
  @moduledoc """
  Adapter Stripe in-memory utilisé en tests. Retourne des réponses
  canned de la même forme que l'API Stripe ; aucun appel réseau.

  Permet aux tests de tourner en CI sans `STRIPE_SECRET_KEY`.
  Le format des maps retournées suit exactement ce que renverrait
  Stripe (clés stringifiées) — comme ça le code prod et le code test
  partagent le même chemin de désérialisation.
  """

  @behaviour KomunBackend.StripeApi

  @impl true
  def create_express_account(_params) do
    id = "acct_mock_#{:rand.uniform(999_999_999)}"

    {:ok,
     %{
       "id" => id,
       "object" => "account",
       "type" => "express",
       "country" => "FR",
       "details_submitted" => false,
       "charges_enabled" => false,
       "payouts_enabled" => false
     }}
  end

  @impl true
  def create_account_link(params) do
    {:ok,
     %{
       "object" => "account_link",
       "url" =>
         "https://connect.stripe.com/setup/e/mock_#{params["account"] || params[:account]}",
       "expires_at" => System.system_time(:second) + 300
     }}
  end

  @impl true
  def retrieve_account(account_id) do
    {:ok,
     %{
       "id" => account_id,
       "object" => "account",
       "details_submitted" => true,
       "charges_enabled" => true,
       "payouts_enabled" => true
     }}
  end

  @impl true
  def create_payment_intent(params) do
    id = "pi_mock_#{:rand.uniform(999_999_999)}"

    {:ok,
     %{
       "id" => id,
       "object" => "payment_intent",
       "status" => "requires_payment_method",
       "amount" => params[:amount] || params["amount"],
       "currency" => params[:currency] || params["currency"] || "eur",
       "client_secret" => "#{id}_secret_mock",
       "application_fee_amount" =>
         params[:application_fee_amount] || params["application_fee_amount"],
       "transfer_data" => params[:transfer_data] || params["transfer_data"]
     }}
  end

  @impl true
  def refund_payment_intent(intent_id, params) do
    {:ok,
     %{
       "id" => "re_mock_#{:rand.uniform(999_999_999)}",
       "object" => "refund",
       "payment_intent" => intent_id,
       "status" => "succeeded",
       "amount" => params[:amount] || params["amount"]
     }}
  end
end
