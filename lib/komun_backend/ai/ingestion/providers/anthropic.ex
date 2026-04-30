defmodule KomunBackend.AI.Ingestion.Providers.Anthropic do
  @moduledoc """
  Client Anthropic Messages API pour l'ingestion AI.

  ## Configuration

    * `ANTHROPIC_API_KEY` (env, runtime) — clé `sk-ant-api03-…`
    * `ANTHROPIC_API_URL` (env, optionnel) — défaut `https://api.anthropic.com`
    * `:anthropic_req_options` (Application env) — options injectées dans
      Req pour stub-er en tests via `Req.Test`.

  ## Format de requête

  POST `/v1/messages` avec :

  ```json
  {
    "model": "claude-opus-4-7",
    "max_tokens": 4096,
    "system": "...",
    "messages": [{"role": "user", "content": "..."}]
  }
  ```

  Headers :

    * `x-api-key: <key>`
    * `anthropic-version: 2023-06-01`
    * `content-type: application/json`

  ## Format de réponse

  ```json
  {
    "id": "msg_…",
    "content": [{"type": "text", "text": "..."}],
    "model": "claude-opus-4-7",
    "stop_reason": "end_turn",
    "usage": {"input_tokens": 6500, "output_tokens": 3000}
  }
  ```

  On extrait le premier bloc `text` (Anthropic peut en théorie en
  renvoyer plusieurs ; pour notre cas mono-tour c'est toujours un seul).
  """

  @behaviour KomunBackend.AI.Ingestion.Provider

  require Logger

  @anthropic_version "2023-06-01"

  @impl true
  def complete(model_id, messages, opts \\ []) do
    case api_key() do
      nil ->
        {:error, :anthropic_api_key_missing}

      key ->
        do_complete(key, model_id, messages, opts)
    end
  end

  defp do_complete(key, model_id, messages, opts) do
    {system, user_messages} = split_system(messages)

    body = %{
      model: model_id,
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      messages: user_messages
    }

    body = if system, do: Map.put(body, :system, system), else: body

    body =
      case Keyword.fetch(opts, :temperature) do
        {:ok, t} -> Map.put(body, :temperature, t)
        :error -> body
      end

    options =
      [
        method: :post,
        url: api_url() <> "/v1/messages",
        json: body,
        headers: [
          {"x-api-key", key},
          {"anthropic-version", @anthropic_version},
          {"content-type", "application/json"}
        ],
        receive_timeout: Keyword.get(opts, :timeout_ms, 60_000),
        retry: false
      ] ++ req_options()

    case Req.request(options) do
      {:ok, %{status: 200, body: body}} ->
        parse_success(body)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[anthropic] HTTP #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.warning("[anthropic] transport error: #{inspect(reason)}")
        {:error, {:transport, reason}}
    end
  end

  # Anthropic veut le system en haut-niveau, pas dans `messages`. On
  # extrait le premier message system rencontré (les autres rôles
  # passent dans `messages`).
  defp split_system(messages) do
    Enum.reduce(messages, {nil, []}, fn
      %{role: "system", content: c}, {nil, acc} -> {c, acc}
      msg, {sys, acc} -> {sys, acc ++ [msg]}
    end)
  end

  defp parse_success(%{"content" => blocks, "usage" => usage} = body) do
    text =
      blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("\n")

    {:ok,
     %{
       content: text,
       input_tokens: usage["input_tokens"] || 0,
       output_tokens: usage["output_tokens"] || 0,
       finish_reason: body["stop_reason"],
       raw: body
     }}
  end

  defp parse_success(other) do
    {:error, {:unexpected_response, other}}
  end

  defp api_key, do: System.get_env("ANTHROPIC_API_KEY")

  defp api_url do
    System.get_env("ANTHROPIC_API_URL", "https://api.anthropic.com")
  end

  defp req_options,
    do: Application.get_env(:komun_backend, :anthropic_req_options, [])
end
