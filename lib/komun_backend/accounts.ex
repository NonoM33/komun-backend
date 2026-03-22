defmodule KomunBackend.Accounts do
  @moduledoc "Authentication and user management context."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Accounts.{User, MagicLink}

  # ── Users ─────────────────────────────────────────────────────────────────

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  def get_or_create_user(email) do
    email = String.downcase(email)
    case Repo.get_by(User, email: email) do
      nil ->
        %User{}
        |> User.changeset(%{email: email})
        |> Repo.insert()
      user ->
        {:ok, user}
    end
  end

  def update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def record_sign_in(user) do
    user
    |> Ecto.Changeset.change(last_sign_in_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
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
