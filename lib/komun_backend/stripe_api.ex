defmodule KomunBackend.StripeApi do
  @moduledoc """
  Façade pour l'API Stripe — wrap les 5 endpoints dont on a besoin.

  L'implémentation réelle est dans `KomunBackend.StripeApi.Http` (utilise
  `Req` pour appeler `api.stripe.com`). En tests, l'adapter est swappé
  pour `KomunBackend.StripeApi.Mock` qui retourne des réponses canned —
  pas besoin d'avoir les credentials Stripe pour faire passer la CI.

  La sélection de l'adapter se fait via la config :

      config :komun_backend, :stripe_api_module, KomunBackend.StripeApi.Mock

  Le module retourne `{:ok, response}` ou `{:error, %{type, message, raw}}`.

  Voir les schémas Stripe pour le format des réponses :
  https://docs.stripe.com/api
  """

  @callback create_express_account(params :: map()) ::
              {:ok, map()} | {:error, map()}
  @callback create_account_link(params :: map()) ::
              {:ok, map()} | {:error, map()}
  @callback retrieve_account(account_id :: String.t()) ::
              {:ok, map()} | {:error, map()}
  @callback create_payment_intent(params :: map()) ::
              {:ok, map()} | {:error, map()}
  @callback refund_payment_intent(intent_id :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, map()}

  defp impl, do: Application.get_env(:komun_backend, :stripe_api_module, __MODULE__.Http)

  def create_express_account(params), do: impl().create_express_account(params)
  def create_account_link(params), do: impl().create_account_link(params)
  def retrieve_account(account_id), do: impl().retrieve_account(account_id)
  def create_payment_intent(params), do: impl().create_payment_intent(params)
  def refund_payment_intent(id, params), do: impl().refund_payment_intent(id, params)
end
