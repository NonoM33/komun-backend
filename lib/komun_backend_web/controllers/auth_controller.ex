defmodule KomunBackendWeb.AuthController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Accounts, Auth.Guardian}
  alias KomunBackend.Notifications.Jobs.SendMagicLinkEmailJob

  # POST /api/v1/auth/magic-link
  # Body: {"email": "user@example.com", "first_name": "...", "last_name": "...", "join_code": "..."}
  #
  # `first_name`, `last_name` and `join_code` are optional: they're the
  # signup payload carried through a /register flow. The names populate
  # the user profile (only if still blank) and the code auto-joins them
  # to the matching residence when they click the link.
  def request_magic_link(conn, %{"email" => email} = params) do
    opts = [
      first_name: params["first_name"],
      last_name: params["last_name"],
      join_code: params["join_code"]
    ]

    with {:ok, token} <- Accounts.create_magic_link(email, opts) do
      # Queue email via Oban
      %{email: email, token: token}
      |> SendMagicLinkEmailJob.new()
      |> Oban.insert()

      json(conn, %{message: "Magic link sent to #{email}"})
    else
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def request_magic_link(conn, _), do: bad_request(conn, "email is required")

  # GET /api/v1/auth/magic-link/verify?token=...
  def verify_magic_link(conn, %{"token" => token}) do
    case Accounts.consume_magic_link(token) do
      {:ok, %{user: user, joined_building: joined}} ->
        {:ok, access_token, _claims} = Guardian.encode_and_sign(user, %{}, ttl: {1, :hour})
        {:ok, refresh_token, _claims} = Guardian.encode_and_sign(user, %{}, token_type: "refresh", ttl: {30, :day})

        Accounts.record_sign_in(user)

        json(conn, %{
          access_token: access_token,
          refresh_token: refresh_token,
          user: user_json(user),
          joined_building: building_json(joined)
        })

      {:error, :invalid_token} ->
        conn |> put_status(401) |> json(%{error: "Invalid or expired token"})

      {:error, :expired_token} ->
        conn |> put_status(401) |> json(%{error: "Token expired, please request a new one"})
    end
  end

  def verify_magic_link(conn, _), do: bad_request(conn, "token is required")

  # POST /api/v1/auth/refresh
  def refresh(conn, %{"refresh_token" => refresh_token}) do
    with {:ok, _old_claims, {new_token, _new_claims}} <- Guardian.exchange(refresh_token, "refresh", "access") do
      json(conn, %{access_token: new_token})
    else
      {:error, _} ->
        conn |> put_status(401) |> json(%{error: "Invalid refresh token"})
    end
  end

  def refresh(conn, _), do: bad_request(conn, "refresh_token is required")

  # POST /api/v1/auth/logout
  def logout(conn, _) do
    json(conn, %{message: "Logged out"})
  end

  # POST /api/v1/auth/dev-login (only when ALLOW_DEV_LOGIN=true env var set)
  def dev_login(conn, %{"email" => email}) do
    unless Application.get_env(:komun_backend, :allow_dev_login, false) do
      conn |> put_status(404) |> json(%{error: "Not found"}) |> halt()
    end

    with {:ok, user} <- Accounts.get_or_create_user(email) do
      {:ok, access_token, _} = Guardian.encode_and_sign(user, %{}, ttl: {1, :hour})
      {:ok, refresh_token, _} = Guardian.encode_and_sign(user, %{}, token_type: "refresh", ttl: {30, :day})
      Accounts.record_sign_in(user)
      json(conn, %{
        access_token: access_token,
        refresh_token: refresh_token,
        user: user_json(user)
      })
    else
      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def dev_login(conn, _), do: bad_request(conn, "email is required")

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp user_json(user) do
    %{
      id: user.id,
      email: user.email,
      role: user.role,
      first_name: user.first_name,
      last_name: user.last_name,
      avatar_url: user.avatar_url
    }
  end

  defp building_json(nil), do: nil
  defp building_json(b) do
    %{
      id: b.id,
      name: b.name,
      address: b.address,
      city: b.city,
      postal_code: b.postal_code
    }
  end

  defp bad_request(conn, msg) do
    conn |> put_status(:bad_request) |> json(%{error: msg})
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
