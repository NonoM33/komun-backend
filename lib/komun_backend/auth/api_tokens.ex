defmodule KomunBackend.Auth.ApiTokens do
  @moduledoc """
  Gestion des Personal Access Tokens (PAT).

  Un PAT permet à un utilisateur — typiquement un membre du conseil
  syndical ou un syndic — d'appeler l'API Komun depuis un script ou
  une intégration externe, sans repasser par le flow magic-link.

  Format du token en clair : `kmn_pat_<32 octets aléatoires base32>`.
  Seul le hash SHA-256 est persisté ; le clair n'est exposé qu'une
  fois, à la création.

  Les rôles autorisés à créer / utiliser un token sont listés dans
  `@allowed_roles`. Tout token rattaché à un utilisateur dont le
  rôle a été rétrogradé en dessous de ce seuil est considéré
  comme inactif (cf. `authenticate/1`).
  """

  import Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.Accounts
  alias KomunBackend.Auth.ApiToken

  # Rôles autorisés à émettre / utiliser un PAT.
  # Le conseil syndical (président + membres), le syndic et le
  # super_admin peuvent piloter l'app par API.
  @allowed_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  @prefix "kmn_pat_"
  @random_bytes 32

  @doc """
  Indique si un utilisateur (ou un rôle d'utilisateur) est autorisé
  à émettre / utiliser un PAT.
  """
  def allowed_role?(%{role: role}), do: role in @allowed_roles
  def allowed_role?(role) when is_atom(role), do: role in @allowed_roles
  def allowed_role?(_), do: false

  @doc """
  Liste blanche des rôles, exposée pour les tests / la doc.
  """
  def allowed_roles, do: @allowed_roles

  @doc """
  Crée un nouveau PAT pour `user`.

  Renvoie `{:ok, %{api_token: api_token, plaintext: "kmn_pat_..."}}`
  où `plaintext` est le seul moment où l'on voit le token en clair.

  Options :
    * `:expires_at` — `DateTime` UTC à laquelle le token expire.
      `nil` (par défaut) = jamais.
  """
  def create_token(user, attrs) do
    if allowed_role?(user) do
      do_create_token(user, attrs)
    else
      {:error, :forbidden}
    end
  end

  defp do_create_token(user, attrs) do
    attrs = normalize_attrs(attrs)
    plaintext = generate_plaintext()
    hash = hash_token(plaintext)
    prefix = String.slice(plaintext, 0, String.length(@prefix) + 4)

    changeset =
      ApiToken.changeset(%ApiToken{}, %{
        name: attrs["name"],
        token_hash: hash,
        token_prefix: prefix,
        user_id: user.id,
        expires_at: attrs["expires_at"]
      })

    case Repo.insert(changeset) do
      {:ok, api_token} -> {:ok, %{api_token: api_token, plaintext: plaintext}}
      {:error, cs} -> {:error, cs}
    end
  end

  defp normalize_attrs(%{} = attrs) do
    Enum.into(attrs, %{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Liste les tokens d'un utilisateur, du plus récent au plus ancien.
  Inclut révoqués et expirés (le frontend les distingue visuellement).
  """
  def list_user_tokens(user_id) do
    from(t in ApiToken, where: t.user_id == ^user_id, order_by: [desc: t.inserted_at])
    |> Repo.all()
  end

  @doc """
  Récupère un token par id, scoping sur user.
  """
  def get_user_token(user_id, id) do
    Repo.get_by(ApiToken, id: id, user_id: user_id)
  end

  @doc """
  Révoque un token (soft : `revoked_at` rempli, hash conservé pour
  pouvoir tracer un éventuel usage post-révocation).
  """
  def revoke_token(%ApiToken{} = token) do
    token
    |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  @doc """
  Vérifie un token en clair (`kmn_pat_...`) reçu dans l'`Authorization`
  header. Renvoie `{:ok, user}` si le token est valide ET que
  l'utilisateur a toujours un rôle autorisé. Sinon `{:error, reason}`.

  Effet de bord : met à jour `last_used_at` pour faciliter l'audit.
  """
  def authenticate(plaintext) when is_binary(plaintext) do
    if String.starts_with?(plaintext, @prefix) do
      hash = hash_token(plaintext)

      case Repo.get_by(ApiToken, token_hash: hash) do
        nil ->
          {:error, :invalid_token}

        %ApiToken{revoked_at: revoked_at} when not is_nil(revoked_at) ->
          {:error, :revoked}

        %ApiToken{expires_at: expires_at} = token ->
          cond do
            expired?(expires_at) ->
              {:error, :expired}

            true ->
              case Accounts.get_user(token.user_id) do
                nil ->
                  {:error, :invalid_token}

                user ->
                  if allowed_role?(user) do
                    touch_last_used(token)
                    {:ok, user}
                  else
                    {:error, :forbidden}
                  end
              end
          end
      end
    else
      {:error, :invalid_token}
    end
  end

  def authenticate(_), do: {:error, :invalid_token}

  defp expired?(nil), do: false
  defp expired?(%DateTime{} = at), do: DateTime.compare(DateTime.utc_now(), at) == :gt

  defp touch_last_used(%ApiToken{} = token) do
    token
    |> Ecto.Changeset.change(%{last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  defp generate_plaintext do
    @prefix <> (:crypto.strong_rand_bytes(@random_bytes) |> Base.url_encode64(padding: false))
  end

  defp hash_token(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end
end
