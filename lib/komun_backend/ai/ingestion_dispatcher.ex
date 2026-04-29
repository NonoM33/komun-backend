defmodule KomunBackend.AI.IngestionDispatcher do
  @moduledoc """
  Forwards inbound-email webhooks to a remote Claude Code routine that
  owns the entire ingestion logic (identify the building, list open
  dossiers, decide append vs. create vs. categorize, write to the Komun
  API).

  This module is a pure relay: it does not interpret or transform the
  payload — whatever Resend sent is forwarded to the routine as the
  request body.

  ## Configuration

  Two env vars, read at runtime:

    * `KOMUN_INGEST_TRIGGER_URL`   — full HTTPS URL of the remote routine
    * `KOMUN_INGEST_TRIGGER_TOKEN` — bearer token expected by the trigger

  If either is missing, every dispatch is a silent no-op (dev / test
  friendly). The HTTP call is fire-and-forget via `Task.Supervisor` so
  the webhook response is never delayed; if the routine is unreachable,
  Resend will redeliver later.
  """

  require Logger

  @doc """
  Asynchronously dispatch a payload to the routine. Returns immediately.

  Returns `:noop` if env vars are missing, otherwise the result of
  `Task.Supervisor.start_child/3`.
  """
  def dispatch_async(payload) when is_map(payload) do
    case {trigger_url(), trigger_token()} do
      {url, token}
      when is_binary(url) and url != "" and is_binary(token) and token != "" ->
        Task.Supervisor.start_child(
          KomunBackend.TaskSupervisor,
          fn -> dispatch(url, token, payload) end,
          restart: :temporary
        )

      _ ->
        Logger.info("[ingest-dispatcher] env vars missing — no-op")
        :noop
    end
  end

  @doc "Synchronous dispatch — useful for tests."
  def dispatch(url, token, payload) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"}
    ]

    options =
      [
        url: url,
        json: payload,
        headers: headers,
        receive_timeout: 10_000,
        retry: false
      ] ++ req_options()

    case Req.request(options) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("[ingest-dispatcher] notified routine: status=#{status}")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "[ingest-dispatcher] routine returned #{status}: #{inspect(body)}"
        )

        :error

      {:error, reason} ->
        Logger.warning("[ingest-dispatcher] HTTP error: #{inspect(reason)}")
        :error
    end
  end

  defp trigger_url, do: System.get_env("KOMUN_INGEST_TRIGGER_URL")
  defp trigger_token, do: System.get_env("KOMUN_INGEST_TRIGGER_TOKEN")

  defp req_options,
    do: Application.get_env(:komun_backend, :ingestion_dispatcher_req_options, [])
end
