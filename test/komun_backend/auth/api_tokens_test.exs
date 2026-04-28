defmodule KomunBackend.Auth.ApiTokensTest do
  @moduledoc """
  Tests du context `KomunBackend.Auth.ApiTokens` :
  émission, hash, validation, révocation, expiration, gating
  par rôle.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.Repo
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.{ApiToken, ApiTokens}

  defp insert_user!(role \\ :membre_cs) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  describe "create_token/2" do
    test "émet un token pour un membre du conseil" do
      user = insert_user!(:membre_cs)

      assert {:ok, %{api_token: %ApiToken{} = stored, plaintext: plaintext}} =
               ApiTokens.create_token(user, %{"name" => "Mon script"})

      assert String.starts_with?(plaintext, "kmn_pat_")
      assert stored.user_id == user.id
      assert stored.name == "Mon script"
      # Le clair n'est jamais persisté
      refute stored.token_hash == plaintext
      # Le préfixe est inclus dans le token mais ne suffit pas à le retrouver
      assert String.starts_with?(plaintext, stored.token_prefix)
    end

    test "émet aussi pour un super_admin et un syndic_manager" do
      for role <- [:super_admin, :syndic_manager, :syndic_staff, :president_cs] do
        user = insert_user!(role)
        assert {:ok, _} = ApiTokens.create_token(user, %{"name" => "tok-#{role}"})
      end
    end

    test "refuse pour un copropriétaire ordinaire" do
      user = insert_user!(:coproprietaire)
      assert {:error, :forbidden} = ApiTokens.create_token(user, %{"name" => "x"})
    end

    test "exige un nom" do
      user = insert_user!(:membre_cs)
      assert {:error, %Ecto.Changeset{errors: errors}} = ApiTokens.create_token(user, %{})
      assert Keyword.has_key?(errors, :name)
    end
  end

  describe "authenticate/1" do
    test "retourne le user pour un token valide et touche last_used_at" do
      user = insert_user!(:president_cs)
      {:ok, %{api_token: token, plaintext: plaintext}} =
        ApiTokens.create_token(user, %{"name" => "valid"})

      assert is_nil(token.last_used_at)

      assert {:ok, fetched_user} = ApiTokens.authenticate(plaintext)
      assert fetched_user.id == user.id

      reloaded = Repo.get!(ApiToken, token.id)
      refute is_nil(reloaded.last_used_at)
    end

    test "refuse un token mal formé" do
      assert {:error, :invalid_token} = ApiTokens.authenticate("nope")
      assert {:error, :invalid_token} = ApiTokens.authenticate("kmn_pat_unknown_xxx")
      assert {:error, :invalid_token} = ApiTokens.authenticate(nil)
    end

    test "refuse un token révoqué" do
      user = insert_user!(:membre_cs)
      {:ok, %{api_token: token, plaintext: plaintext}} =
        ApiTokens.create_token(user, %{"name" => "to revoke"})

      {:ok, _} = ApiTokens.revoke_token(token)
      assert {:error, :revoked} = ApiTokens.authenticate(plaintext)
    end

    test "refuse un token expiré" do
      user = insert_user!(:membre_cs)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      {:ok, %{plaintext: plaintext}} =
        ApiTokens.create_token(user, %{"name" => "expired", "expires_at" => past})

      assert {:error, :expired} = ApiTokens.authenticate(plaintext)
    end

    test "refuse un token dont le porteur a été rétrogradé" do
      user = insert_user!(:membre_cs)
      {:ok, %{plaintext: plaintext}} = ApiTokens.create_token(user, %{"name" => "rolling"})

      # Rôle perdu : le token doit être inutilisable même s'il est encore en DB.
      user
      |> Ecto.Changeset.change(%{role: :coproprietaire})
      |> Repo.update!()

      assert {:error, :forbidden} = ApiTokens.authenticate(plaintext)
    end
  end

  describe "list_user_tokens/1 + revoke_token/1" do
    test "ne renvoie que les tokens de l'utilisateur" do
      user_a = insert_user!(:membre_cs)
      user_b = insert_user!(:membre_cs)

      {:ok, _} = ApiTokens.create_token(user_a, %{"name" => "A1"})
      {:ok, _} = ApiTokens.create_token(user_a, %{"name" => "A2"})
      {:ok, _} = ApiTokens.create_token(user_b, %{"name" => "B1"})

      assert length(ApiTokens.list_user_tokens(user_a.id)) == 2
      assert length(ApiTokens.list_user_tokens(user_b.id)) == 1
    end

    test "revoke_token/1 marque revoked_at" do
      user = insert_user!(:membre_cs)
      {:ok, %{api_token: token}} = ApiTokens.create_token(user, %{"name" => "x"})
      assert is_nil(token.revoked_at)

      assert {:ok, revoked} = ApiTokens.revoke_token(token)
      refute is_nil(revoked.revoked_at)
    end
  end
end
