defmodule KomunBackend.AI.Groq do
  @moduledoc """
  Minimal Groq client for the Komun chatbot.

  Model: `openai/gpt-oss-120b` (configurable via GROQ_MODEL env var).
  The Groq API mirrors the OpenAI chat-completions contract, so the payload
  below is the familiar `{messages, model, temperature, …}` shape.

  The key is read at call time from the `GROQ_API_KEY` env var. In test we
  short-circuit when the key is missing so suites don't need network.
  """

  require Logger

  @endpoint "https://api.groq.com/openai/v1/chat/completions"
  @default_model "openai/gpt-oss-120b"
  @default_temperature 0.2
  @default_max_tokens 1024
  @default_timeout_ms 30_000

  @type message :: %{role: :system | :user | :assistant, content: String.t()}

  @spec complete(messages :: [message()], opts :: keyword()) ::
          {:ok,
           %{
             content: String.t(),
             model: String.t(),
             usage: map(),
             finish_reason: String.t() | nil
           }}
          | {:error, atom() | String.t()}
  def complete(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("GROQ_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      model = Keyword.get(opts, :model) || System.get_env("GROQ_MODEL") || @default_model
      temperature = Keyword.get(opts, :temperature, @default_temperature)
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

      body = %{
        model: model,
        messages: Enum.map(messages, fn m -> %{role: to_string(m.role), content: m.content} end),
        temperature: temperature,
        max_tokens: max_tokens
      }

      req_options =
        [
          url: @endpoint,
          headers: [
            {"Authorization", "Bearer #{api_key}"},
            {"Content-Type", "application/json"}
          ],
          json: body,
          receive_timeout: timeout,
          retry: :transient,
          max_retries: 2
        ]
        |> Keyword.merge(Application.get_env(:komun_backend, :groq_req_options, []))

      req = Req.new(req_options)

      case Req.post(req) do
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => content}} = choice | _]} = payload
         }} ->
          usage = Map.get(payload, "usage", %{})

          {:ok,
           %{
             content: content,
             model: Map.get(payload, "model", model),
             usage: %{
               prompt: Map.get(usage, "prompt_tokens"),
               completion: Map.get(usage, "completion_tokens")
             },
             finish_reason: Map.get(choice, "finish_reason")
           }}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("Groq #{status}: #{inspect(body)}")
          {:error, "groq_http_#{status}"}

        {:error, reason} ->
          Logger.error("Groq request failed: #{inspect(reason)}")
          {:error, :network_error}
      end
    end
  end
end
