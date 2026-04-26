defmodule KomunBackend.StripeApi.Http do
  @moduledoc """
  Adapter HTTP réel pour Stripe — utilise `Req` pour appeler
  `api.stripe.com/v1/*`. Auth Basic avec `STRIPE_SECRET_KEY` côté env.

  Si la clé Stripe n'est pas configurée (cas dev local sans Stripe), on
  retourne `{:error, %{type: :stripe_disabled, …}}` pour permettre à
  l'appelant de surface une erreur claire ("Stripe not configured")
  plutôt que de crasher au démarrage de l'app.

  ⚠️ JAMAIS de log du body — la réponse contient les données de
  paiement sensibles (last4 carte, customer email, …).
  """

  @behaviour KomunBackend.StripeApi

  @base_url "https://api.stripe.com/v1"

  @impl true
  def create_express_account(params) do
    post("/accounts", merge_express_defaults(params))
  end

  @impl true
  def create_account_link(params) do
    post("/account_links", params)
  end

  @impl true
  def retrieve_account(account_id) do
    get("/accounts/#{URI.encode_www_form(account_id)}")
  end

  @impl true
  def create_payment_intent(params) do
    post("/payment_intents", params)
  end

  @impl true
  def refund_payment_intent(intent_id, params) do
    body = Map.put(params, :payment_intent, intent_id)
    post("/refunds", body)
  end

  defp merge_express_defaults(params) do
    Map.merge(
      %{
        type: "express",
        country: "FR",
        capabilities: %{
          transfers: %{requested: true},
          card_payments: %{requested: true}
        }
      },
      params
    )
  end

  defp post(path, body) do
    case secret_key() do
      nil -> {:error, %{type: :stripe_disabled, message: "STRIPE_SECRET_KEY missing"}}
      key -> request(:post, path, body, key)
    end
  end

  defp get(path) do
    case secret_key() do
      nil -> {:error, %{type: :stripe_disabled, message: "STRIPE_SECRET_KEY missing"}}
      key -> request(:get, path, nil, key)
    end
  end

  defp request(method, path, body, secret_key) do
    url = @base_url <> path
    auth = {:basic, "#{secret_key}:"}

    # Stripe API attend du form-urlencoded, PAS du JSON. On flatten les maps
    # imbriquées en notation `parent[child]=value` (convention Stripe).
    form = encode_form(body)

    opts =
      [auth: auth, headers: [{"stripe-version", "2024-10-28.acacia"}]]
      |> add_form_body(method, form)

    case Req.request([method: method, url: url] ++ opts) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        {:error,
         %{
           type: :stripe_error,
           status: status,
           code: get_in(resp_body, ["error", "code"]),
           message: get_in(resp_body, ["error", "message"]) || "Stripe error",
           raw: resp_body
         }}

      {:error, reason} ->
        {:error, %{type: :http_error, message: "Stripe HTTP failure", raw: reason}}
    end
  end

  defp add_form_body(opts, :get, _), do: opts
  defp add_form_body(opts, _, nil), do: opts
  defp add_form_body(opts, _, ""), do: opts
  defp add_form_body(opts, _, form), do: Keyword.put(opts, :form, form)

  # Encode une map vers le format form-encoded attendu par Stripe :
  # %{a: 1, b: %{c: 2}} → [{"a", "1"}, {"b[c]", "2"}].
  defp encode_form(nil), do: ""

  defp encode_form(map) when is_map(map) do
    map
    |> Enum.flat_map(fn {k, v} -> flatten(to_string(k), v) end)
  end

  defp flatten(key, value) when is_map(value) do
    value
    |> Enum.flat_map(fn {k, v} -> flatten("#{key}[#{k}]", v) end)
  end

  defp flatten(key, value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, idx} -> flatten("#{key}[#{idx}]", v) end)
  end

  defp flatten(key, value) when is_boolean(value),
    do: [{key, to_string(value)}]

  defp flatten(_key, value) when is_nil(value), do: []

  defp flatten(key, value), do: [{key, to_string(value)}]

  defp secret_key, do: System.get_env("STRIPE_SECRET_KEY")
end
