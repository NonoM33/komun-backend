defmodule KomunBackendWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Custom `Plug.Parsers` body reader that retains the raw request body in
  `conn.assigns[:raw_body]` for webhook paths that need HMAC signature
  verification (Stripe, Resend / Svix).

  Wired up in `endpoint.ex` via the `body_reader:` option of
  `Plug.Parsers`. The capture is gated by path prefix so we don't pay
  the memory cost of duplicating bodies on every API request.

  Resend webhooks can carry attachments base64-encoded — payloads in the
  multi-MB range are realistic. Capturing only `/api/v1/webhooks/*` keeps
  the rest of the API at zero overhead.
  """

  @captured_prefix "/api/v1/webhooks/"

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    conn =
      if String.starts_with?(conn.request_path || "", @captured_prefix) do
        Plug.Conn.assign(conn, :raw_body, body)
      else
        conn
      end

    {:ok, body, conn}
  end
end
