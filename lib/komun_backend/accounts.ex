defmodule KomunBackend.Accounts do
  @moduledoc "Authentication and user management context."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Accounts.{User, MagicLink}
  alias KomunBackend.Audit
  alias KomunBackend.Buildings

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

  @doc """
  Met à jour le rôle global d'un utilisateur. Trace la mutation dans
  `role_audit_log` (cf. `KomunBackend.Audit`).

  Options :
  - `:source` (atom) — origine, default `:admin_panel`
  - `:actor_id` — qui a déclenché (admin)
  - `:metadata` — map libre (ex: request_id, IP)
  """
  def update_user_role(user_id, role, opts \\ []) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      %User{role: current_role} = user ->
        result = user |> User.changeset(%{role: role}) |> Repo.update()

        case result do
          {:ok, updated} ->
            Audit.record_role_change(%{
              scope: :global,
              source: Keyword.get(opts, :source, :admin_panel),
              user_id: updated.id,
              old_role: current_role,
              new_role: updated.role,
              actor_id: Keyword.get(opts, :actor_id),
              metadata: Keyword.get(opts, :metadata, %{})
            })

            {:ok, updated}

          {:error, _} = err ->
            err
        end
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

  @doc """
  Creates a magic link for `email`.

  `opts` may carry signup payload that gets applied the first time the
  link is consumed:

    * `:first_name` / `:last_name` — applied to the user record if that
      user still has them blank (we never overwrite an existing name).
    * `:join_code` — residence short-code. If it matches an active
      building, the user is auto-joined on first consume. Unknown codes
      are dropped silently; the user still lands logged-in so they can
      retry from `/join`.
  """
  def create_magic_link(email, opts \\ []) when is_binary(email) do
    token = MagicLink.generate_token()
    token_hash = MagicLink.hash_token(token)
    normalized_email = String.downcase(email)

    # Invalide tous les liens précédents encore actifs pour ce mail. Le
    # flow register → /login peut pousser un user à redemander un lien
    # alors qu'il en a déjà un en attente. Sans ça, le vieux lien reste
    # valide 15 min et l'user clique dessus par erreur, ce qui peut
    # créer de la confusion (ex. Pascale). "Seul le dernier lien
    # fonctionne" — comportement standard des magic-link systems.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(ml in MagicLink,
      where: ml.email == ^normalized_email and is_nil(ml.used_at)
    )
    |> Repo.update_all(set: [used_at: now])

    attrs = %{
      email: normalized_email,
      token_hash: token_hash,
      expires_at: MagicLink.expires_at(),
      first_name: trim_or_nil(Keyword.get(opts, :first_name)),
      last_name: trim_or_nil(Keyword.get(opts, :last_name)),
      join_code: trim_or_nil(Keyword.get(opts, :join_code))
    }

    with {:ok, _} <- %MagicLink{} |> MagicLink.changeset(attrs) |> Repo.insert() do
      {:ok, token}
    end
  end

  defp trim_or_nil(nil), do: nil
  defp trim_or_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end
  defp trim_or_nil(_), do: nil

  @doc """
  Redeems a magic link.

  Returns `{:ok, %{user: user, joined_building: building | nil}}` so the
  caller can inform the frontend that onboarding already placed the
  resident in a residence (and skip the /join gate). If anything goes
  wrong with the auto-join we still return the user with
  `joined_building: nil` — the regular /join flow is still available.
  """
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

          case get_or_create_user(magic_link.email) do
            {:ok, user} ->
              user = apply_signup_profile(user, magic_link)
              joined = maybe_auto_join(user, magic_link)
              %{user: user, joined_building: joined}

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
  end

  # Fills in first_name / last_name if the magic link carried them *and*
  # the user record is still blank. We never overwrite a name the user
  # may have edited themselves.
  defp apply_signup_profile(user, %MagicLink{first_name: fn_in, last_name: ln_in})
       when not (is_nil(fn_in) and is_nil(ln_in)) do
    updates =
      %{}
      |> maybe_put_if_blank(:first_name, user.first_name, fn_in)
      |> maybe_put_if_blank(:last_name, user.last_name, ln_in)

    if map_size(updates) == 0 do
      user
    else
      case user |> User.changeset(updates) |> Repo.update() do
        {:ok, updated} -> updated
        {:error, _} -> user
      end
    end
  end
  defp apply_signup_profile(user, _), do: user

  defp maybe_put_if_blank(acc, _key, _existing, nil), do: acc
  defp maybe_put_if_blank(acc, key, existing, incoming) do
    if is_nil(existing) or existing == "" do
      Map.put(acc, key, incoming)
    else
      acc
    end
  end

  # Auto-joins the user to the building matching `join_code`, if one
  # exists. We swallow errors here — the magic-link consume shouldn't
  # fail the login just because the join couldn't be applied; the user
  # can still retry via the /join page.
  defp maybe_auto_join(user, %MagicLink{join_code: code}) when is_binary(code) do
    case Buildings.join_by_code(code, user.id) do
      {:ok, {:already_member, building}} -> building
      {:ok, {building, _member}} -> building
      _ -> nil
    end
  end
  defp maybe_auto_join(_user, _), do: nil

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
