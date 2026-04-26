defmodule KomunBackendWeb.AuthController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Accounts, Auth.Guardian}
  alias KomunBackend.Notifications.Jobs.SendMagicLinkEmailJob

  # POST /api/v1/auth/magic-link
  # Body: {"email": "user@example.com", "first_name": "...", "last_name": "...",
  #        "join_code": "...", "building_id": "..."}
  #
  # `first_name`, `last_name`, `join_code` et `building_id` sont optionnels :
  # ils forment le payload de signup transporté dans le flow /register. Les
  # noms remplissent le profil si blanc, et on auto-join à l'inscription :
  # - Si `building_id` est fourni → on le résout côté serveur en son code
  #   bâtiment (le user vient de le choisir dans la page d'inscription après
  #   avoir tapé un code résidence).
  # - Sinon `join_code` est utilisé tel quel (typiquement un code bâtiment
  #   direct, ou un code résidence mono-bâtiment).
  def request_magic_link(conn, %{"email" => email} = params) do
    resolved_code =
      case params["building_id"] do
        bid when is_binary(bid) and bid != "" ->
          # Safe lookup — un building_id invalide (uuid mal formé, ID disparu)
          # ne doit pas faire tomber l'endpoint magic-link.
          try do
            case KomunBackend.Repo.get(KomunBackend.Buildings.Building, bid) do
              %{join_code: code} when is_binary(code) -> code
              _ -> params["join_code"]
            end
          rescue
            _ -> params["join_code"]
          end

        _ ->
          params["join_code"]
      end

    opts = [
      first_name: params["first_name"],
      last_name: params["last_name"],
      join_code: resolved_code
    ]

    with {:ok, %{token: token, code: code}} <- Accounts.create_magic_link(email, opts) do
      # Queue email via Oban — on transmet token (lien) et code (6 digits)
      # pour que l'utilisateur puisse choisir : cliquer le lien (Safari)
      # ou taper le code dans l'app standalone.
      %{email: email, token: token, code: code}
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
        {:ok, access_token, _claims} = Guardian.encode_and_sign(user, %{}, ttl: {24, :hour})
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

  # POST /api/v1/auth/magic-code/verify
  # Body: { "email": "...", "code": "123456" }
  #
  # Endpoint dédié à la PWA iOS standalone : un clic sur le lien magic
  # ouvre Safari (jamais l'app standalone), donc les tokens posés sont
  # dans le mauvais contexte. Avec ce flow, l'utilisateur reste dans
  # la PWA, regarde le code dans son app Mail, le recopie, c'est joué.
  def verify_magic_code(conn, %{"email" => email, "code" => code})
      when is_binary(email) and is_binary(code) do
    # Tolère les espaces et le formatage type "123 456" / "123-456".
    cleaned = code |> String.replace(~r/[\s\-]/, "") |> String.trim()

    case Accounts.consume_magic_code(email, cleaned) do
      {:ok, %{user: user, joined_building: joined}} ->
        {:ok, access_token, _claims} = Guardian.encode_and_sign(user, %{}, ttl: {24, :hour})

        {:ok, refresh_token, _claims} =
          Guardian.encode_and_sign(user, %{}, token_type: "refresh", ttl: {30, :day})

        Accounts.record_sign_in(user)

        json(conn, %{
          access_token: access_token,
          refresh_token: refresh_token,
          user: user_json(user),
          joined_building: building_json(joined)
        })

      {:error, :invalid_code} ->
        conn |> put_status(401) |> json(%{error: "Code invalide ou expiré"})

      {:error, :expired_code} ->
        conn |> put_status(401) |> json(%{error: "Code expiré, redemandez-en un nouveau"})
    end
  end

  def verify_magic_code(conn, _), do: bad_request(conn, "email and code are required")

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
      {:ok, access_token, _} = Guardian.encode_and_sign(user, %{}, ttl: {24, :hour})
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
