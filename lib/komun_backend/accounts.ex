defmodule KomunBackend.Accounts do
  @moduledoc "Authentication and user management context."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Accounts.{User, MagicLink}

  @super_admin_email "renaudlemagicien@gmail.com"

  # ── Users ─────────────────────────────────────────────────────────────────

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  def get_or_create_user(email) do
    email = String.downcase(email)
    case Repo.get_by(User, email: email) do
      nil ->
        role = if email == @super_admin_email, do: :super_admin, else: :coproprietaire
        %User{}
        |> User.changeset(%{email: email, role: role})
        |> Repo.insert()
      user ->
        # Upgrade to super_admin if it's the seed admin email and not already
        if email == @super_admin_email and user.role != :super_admin do
          user |> User.changeset(%{role: :super_admin}) |> Repo.update()
        else
          {:ok, user}
        end
    end
  end

  def list_users do
    Repo.all(User)
  end

  def update_user_role(user_id, role) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> user |> User.changeset(%{role: role}) |> Repo.update()
    end
  end

  def update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Permanently deletes a user. All associations configured with
  `on_delete: :delete_all` (building_members, incidents they reported,
  assistant_messages, chat_messages, push tokens, etc.) cascade at the
  DB level. Callers should gate this behind super_admin in the
  controller — there is no policy check here.
  """
  def delete_user(%User{} = user), do: Repo.delete(user)

  def delete_user(user_id) when is_binary(user_id) do
    case get_user(user_id) do
      nil -> {:error, :not_found}
      user -> delete_user(user)
    end
  end

  def record_sign_in(user) do
    user
    |> Ecto.Changeset.change(last_sign_in_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc """
  Stamps the AI-assistant rate-limit cursor. Called after a successful
  Groq completion so the user is locked out for the next 24h window.
  """
  def touch_last_chat_at(user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case user
         |> Ecto.Changeset.change(last_chat_at: now)
         |> Repo.update() do
      {:ok, updated} -> updated
      _ -> user
    end
  end

  # ── Magic links ───────────────────────────────────────────────────────────

  def create_magic_link(email) do
    token = MagicLink.generate_token()
    token_hash = MagicLink.hash_token(token)

    attrs = %{
      email: String.downcase(email),
      token_hash: token_hash,
      expires_at: MagicLink.expires_at()
    }

    with {:ok, _} <- %MagicLink{} |> MagicLink.changeset(attrs) |> Repo.insert() do
      {:ok, token}
    end
  end

  def consume_magic_link(token) do
    token_hash = MagicLink.hash_token(token)

    Repo.transaction(fn ->
      magic_link =
        from(ml in MagicLink,
          where: ml.token_hash == ^token_hash and is_nil(ml.used_at)
        )
        |> Repo.one()

      cond do
        is_nil(magic_link) ->
          Repo.rollback(:invalid_token)

        not MagicLink.valid?(magic_link) ->
          Repo.rollback(:expired_token)

        true ->
          magic_link
          |> Ecto.Changeset.change(used_at: DateTime.utc_now() |> DateTime.truncate(:second))
          |> Repo.update!()

          get_or_create_user(magic_link.email)
      end
    end)
  end

  def cleanup_expired_magic_links do
    from(ml in MagicLink,
      where: ml.expires_at < ^DateTime.utc_now() or not is_nil(ml.used_at)
    )
    |> Repo.delete_all()
  end

  # ── Push tokens ───────────────────────────────────────────────────────────

  def register_push_token(user, token) do
    tokens = (user.push_tokens || []) |> Enum.reject(&(&1 == token))
    update_user(user, %{push_tokens: [token | tokens]})
  end

  def unregister_push_token(user, token) do
    tokens = (user.push_tokens || []) |> Enum.reject(&(&1 == token))
    update_user(user, %{push_tokens: tokens})
  end
end
