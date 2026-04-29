defmodule KomunBackendWeb.WebhookControllerTest do
  @moduledoc """
  Tests pour le webhook Resend Inbound (pur relais Svix HMAC).

  Pas de logique métier ici : on vérifie que (1) la signature est
  correctement validée et (2) le payload est bien forwardé tel quel
  au dispatcher (qui lui appelle la routine Claude).
  """

  use KomunBackendWeb.ConnCase, async: false

  # Resend ne supporte pas les headers d'auth custom — on vérifie la
  # signature Svix HMAC. Ces tests forgent une signature valide pour
  # passer le check (ou la cassent volontairement pour tester le rejet).
  @raw_secret "test-resend-signing-secret-1234567890ab"
  @signing_secret "whsec_" <> Base.encode64(@raw_secret)

  setup do
    previous_secret = System.get_env("RESEND_WEBHOOK_SIGNING_SECRET")
    System.put_env("RESEND_WEBHOOK_SIGNING_SECRET", @signing_secret)

    on_exit(fn ->
      if previous_secret,
        do: System.put_env("RESEND_WEBHOOK_SIGNING_SECRET", previous_secret),
        else: System.delete_env("RESEND_WEBHOOK_SIGNING_SECRET")
    end)

    :ok
  end

  defp sign(body, opts \\ []) do
    id = Keyword.get(opts, :id, "msg_#{System.unique_integer([:positive])}")
    ts = Keyword.get(opts, :timestamp, System.system_time(:second)) |> to_string()
    secret = Keyword.get(opts, :secret, @raw_secret)

    sig =
      :crypto.mac(:hmac, :sha256, secret, "#{id}.#{ts}.#{body}")
      |> Base.encode64()

    {id, ts, "v1,#{sig}"}
  end

  defp post_inbound(conn, payload, opts \\ []) do
    body = Jason.encode!(payload)
    {id, ts, sig} = sign(body, opts)

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("webhook-id", id)
    |> Plug.Conn.put_req_header("webhook-timestamp", ts)
    |> Plug.Conn.put_req_header("webhook-signature", sig)
    |> post("/api/v1/webhooks/resend/inbound", body)
  end

  test "rejects without webhook-* headers", %{conn: conn} do
    response =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/api/v1/webhooks/resend/inbound", Jason.encode!(%{}))

    assert response.status == 401
  end

  test "rejects when signature does not match the body", %{conn: conn} do
    payload = %{"foo" => "bar"}
    body = Jason.encode!(payload)
    {id, ts, _good_sig} = sign(body)
    bad_sig = "v1,#{Base.encode64("nope")}"

    response =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("webhook-id", id)
      |> Plug.Conn.put_req_header("webhook-timestamp", ts)
      |> Plug.Conn.put_req_header("webhook-signature", bad_sig)
      |> post("/api/v1/webhooks/resend/inbound", body)

    assert response.status == 401
  end

  test "rejects when timestamp is too old (replay protection)", %{conn: conn} do
    payload = %{"from" => %{"email" => "x@y.z"}, "subject" => "S"}
    # 1h dans le passé → > 5 min de tolérance
    old_ts = System.system_time(:second) - 3600
    response = post_inbound(conn, payload, timestamp: old_ts)
    assert response.status == 401
  end

  test "accepts a valid signature and returns 200 forwarded", %{conn: conn} do
    payload = %{
      "from" => %{"email" => "voisin@gmail.com", "name" => "Voisin"},
      "to" => [%{"email" => "test-alias-1@inbound.komun.app"}],
      "subject" => "Panne ascenseur",
      "text" => "L'ascenseur ne répond plus depuis ce matin",
      "date" => "2026-04-28T10:00:00Z"
    }

    response = post_inbound(conn, payload)
    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert body["forwarded"] == true
  end

  test "rejects when RESEND_WEBHOOK_SIGNING_SECRET is missing", %{conn: conn} do
    System.delete_env("RESEND_WEBHOOK_SIGNING_SECRET")

    payload = %{"foo" => "bar"}
    response = post_inbound(conn, payload)

    assert response.status == 401
  end
end
