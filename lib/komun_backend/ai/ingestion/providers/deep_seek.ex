defmodule KomunBackend.AI.Ingestion.Providers.DeepSeek do
  @moduledoc """
  Client DeepSeek (compatible OpenAI Chat Completions) pour l'ingestion AI.

  ## Configuration

    * `DEEPSEEK_API_KEY` (env, runtime) — clé `sk-…`
    * `DEEPSEEK_API_URL` (env, optionnel) — défaut `https://api.deepseek.com`
    * `:deepseek_req_options` (Application env) — stub Req.Test en tests.

  ## Mapping des `model_id` Komun vers DeepSeek

  Komun utilise des ids stables (`deepseek-v4-flash`) ; DeepSeek expose
  ses modèles sous des noms propres (`deepseek-chat-v4-flash`,
  `deepseek-reasoner-v4-pro`, etc.). On fait la correspondance ici pour
  rester découplé — si DeepSeek renomme demain, on patch juste cette
  fonction sans toucher au registre Komun.

  ## Format de requête (compatible OpenAI)

  POST `/v1/chat/completions` avec :

  ```json
  {
    "model": "deepseek-chat",
    "max_tokens": 4096,
    "messages": [
      {"role": "system", "content": "..."},
      {"role": "user", "content": "..."}
    ]
  }
  ```

  Headers :

    * `Authorization: Bearer <key>`
    * `Content-Type: application/json`
  """

  @behaviour KomunBackend.AI.Ingestion.Provider

  require Logger

  @impl true
  def complete(model_id, messages, opts \\ []) do
    case api_key() do
      nil ->
        {:error, :deepseek_api_key_missing}

      key ->
        do_complete(key, model_id, messages, opts)
    end
  end

  defp do_complete(key, model_id, messages, opts) do
    body = %{
      model: deepseek_model_name(model_id),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      messages: messages
    }

    body =
      case Keyword.fetch(opts, :temperature) do
        {:ok, t} -> Map.put(body, :temperature, t)
        :error -> body
      end

    options =
      [
        method: :post,
        url: api_url() <> "/v1/chat/completions",
        json: body,
        headers: [
          {"authorization", "Bearer #{key}"},
          {"content-type", "application/json"}
        ],
        receive_timeout: Keyword.get(opts, :timeout_ms, 60_000),
        retry: false
      ] ++ req_options()

    case Req.request(options) do
      {:ok, %{status: 200, body: body}} ->
        parse_success(body)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[deepseek] HTTP #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.warning("[deepseek] transport error: #{inspect(reason)}")
        {:error, {:transport, reason}}
    end
  end

  # Mapping Komun id → nom interne DeepSeek. À ajuster quand DeepSeek
  # change ses identifiants ou en sort de nouveaux.
  defp deepseek_model_name("deepseek-v4-flash"), do: "deepseek-chat"
  defp deepseek_model_name("deepseek-v4-pro"), do: "deepseek-reasoner"
  defp deepseek_model_name(other), do: other

  defp parse_success(%{"choices" => [%{"message" => %{"content" => content}, "finish_reason" => fr} | _], "usage" => usage} = body) do
    {:ok,
     %{
       content: content,
       input_tokens: usage["prompt_tokens"] || 0,
       output_tokens: usage["completion_tokens"] || 0,
       finish_reason: fr,
       raw: body
     }}
  end

  defp parse_success(other) do
    {:error, {:unexpected_response, other}}
  end

  defp api_key, do: System.get_env("DEEPSEEK_API_KEY")

  defp api_url do
    System.get_env("DEEPSEEK_API_URL", "https://api.deepseek.com")
  end

  defp req_options,
    do: Application.get_env(:komun_backend, :deepseek_req_options, [])
end
