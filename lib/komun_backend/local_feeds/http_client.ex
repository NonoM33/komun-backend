defmodule KomunBackend.LocalFeeds.HttpClient do
  @moduledoc """
  Wrapper Req pour le worker RSS. Isolé dans un module pour permettre
  l'injection d'un stub en test (`config :komun_backend, :rss_http_client`).

  Cap les responses à `max_response_bytes` (5 MB par défaut). Limite
  les redirections (3 max). Ajoute un User-Agent identifiable.
  """

  @behaviour KomunBackend.LocalFeeds.HttpClient.Behaviour

  @impl true
  def get(url, opts \\ []) do
    user_agent = Keyword.get(opts, :user_agent, "KomunBot/1.0")
    max_redirects = Keyword.get(opts, :max_redirects, 3)
    receive_timeout = Keyword.get(opts, :receive_timeout, 10_000)
    connect_timeout = Keyword.get(opts, :connect_timeout, 5_000)
    max_response_bytes = Keyword.get(opts, :max_response_bytes, 5 * 1024 * 1024)

    req =
      Req.new(
        url: url,
        max_redirects: max_redirects,
        receive_timeout: receive_timeout,
        connect_options: [timeout: connect_timeout],
        headers: [
          {"user-agent", user_agent},
          {"accept", "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.5"}
        ]
      )

    case Req.get(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        validate_size(body, max_response_bytes)

      {:ok, %Req.Response{status: status}} ->
        {:error, "http_status_#{status}"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "transport_#{reason}"}

      {:error, exception} when is_exception(exception) ->
        {:error, "http_error: #{Exception.message(exception)}"}

      {:error, reason} ->
        {:error, "http_error: #{inspect(reason)}"}
    end
  end

  defp validate_size(body, max) when is_binary(body) do
    if byte_size(body) > max do
      {:error, "response_too_large"}
    else
      {:ok, body}
    end
  end

  defp validate_size(body, _max), do: {:ok, to_string(body)}
end

defmodule KomunBackend.LocalFeeds.HttpClient.Behaviour do
  @moduledoc false
  @callback get(url :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}
end
