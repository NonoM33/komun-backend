defmodule KomunBackend.AccountsTest do
  use KomunBackend.DataCase, async: false

  alias KomunBackend.Accounts

  defp unique_email(prefix \\ "user") do
    "#{prefix}-#{System.unique_integer([:positive])}@komun.app"
  end

  describe "get_or_create_user/1" do
    test "crée un utilisateur coproprietaire par défaut" do
      email = unique_email()
      assert {:ok, user} = Accounts.get_or_create_user(email)
      assert user.email == email
      assert user.role == :coproprietaire
    end

    test "normalise l'email en minuscules" do
      email = "MixedCase-#{System.unique_integer([:positive])}@Komun.App"
      assert {:ok, user} = Accounts.get_or_create_user(email)
      assert user.email == String.downcase(email)
    end

    test "retourne l'utilisateur existant sans en créer un nouveau" do
      email = unique_email()
      assert {:ok, first} = Accounts.get_or_create_user(email)
      assert {:ok, second} = Accounts.get_or_create_user(email)
      assert first.id == second.id
    end

    test "attribue super_admin à l'email seed admin" do
      assert {:ok, user} = Accounts.get_or_create_user("renaudlemagicien@gmail.com")
      assert user.role == :super_admin
    end

    test "upgrade un utilisateur existant vers super_admin si c'est l'email seed" do
      {:ok, user} =
        %KomunBackend.Accounts.User{}
        |> KomunBackend.Accounts.User.changeset(%{
          email: "renaudlemagicien@gmail.com",
          role: :coproprietaire
        })
        |> Repo.insert()

      assert user.role == :coproprietaire

      assert {:ok, upgraded} = Accounts.get_or_create_user("renaudlemagicien@gmail.com")
      assert upgraded.id == user.id
      assert upgraded.role == :super_admin
    end
  end

  describe "get_user_by_email/1" do
    test "trouve un utilisateur quelle que soit la casse fournie" do
      email = unique_email()
      {:ok, user} = Accounts.get_or_create_user(email)

      assert Accounts.get_user_by_email(String.upcase(email)).id == user.id
    end

    test "retourne nil pour un email inconnu" do
      assert Accounts.get_user_by_email(unique_email("unknown")) == nil
    end
  end

  describe "get_user/1 and list_users/0" do
    test "get_user/1 retourne l'utilisateur par id" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())
      assert Accounts.get_user(user.id).id == user.id
    end

    test "list_users/0 remonte les utilisateurs créés" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())
      ids = Accounts.list_users() |> Enum.map(& &1.id)
      assert user.id in ids
    end
  end

  describe "unicité de l'email" do
    test "empêche la création de deux utilisateurs avec le même email" do
      email = unique_email()

      {:ok, _} =
        %KomunBackend.Accounts.User{}
        |> KomunBackend.Accounts.User.changeset(%{email: email})
        |> Repo.insert()

      assert {:error, cs} =
               %KomunBackend.Accounts.User{}
               |> KomunBackend.Accounts.User.changeset(%{email: email})
               |> Repo.insert()

      assert %{email: _} = errors_on(cs)
    end
  end

  describe "update_user/2" do
    test "met à jour le profil" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())
      assert {:ok, updated} = Accounts.update_user(user, %{first_name: "Alice"})
      assert updated.first_name == "Alice"
    end

    test "rejette un email invalide" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())
      assert {:error, cs} = Accounts.update_user(user, %{email: "pas un email"})
      assert %{email: _} = errors_on(cs)
    end
  end

  describe "update_user_role/3" do
    test "change le rôle et retourne l'utilisateur mis à jour" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())

      assert {:ok, updated} = Accounts.update_user_role(user.id, :president_cs)
      assert updated.role == :president_cs
    end

    test "retourne {:error, :not_found} pour un id inconnu" do
      assert {:error, :not_found} = Accounts.update_user_role(Ecto.UUID.generate(), :membre_cs)
    end
  end

  describe "delete_user/1" do
    test "supprime un utilisateur par struct" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())
      assert {:ok, _} = Accounts.delete_user(user)
      assert Accounts.get_user(user.id) == nil
    end

    test "supprime un utilisateur par id" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())
      assert {:ok, _} = Accounts.delete_user(user.id)
      assert Accounts.get_user(user.id) == nil
    end

    test "retourne {:error, :not_found} pour un id inconnu" do
      assert {:error, :not_found} = Accounts.delete_user(Ecto.UUID.generate())
    end
  end

  describe "record_sign_in/1 et touch_last_chat_at/1" do
    test "record_sign_in/1 pose last_sign_in_at" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())
      assert user.last_sign_in_at == nil
      assert {:ok, updated} = Accounts.record_sign_in(user)
      assert updated.last_sign_in_at != nil
    end

    test "touch_last_chat_at/1 pose last_chat_at et renvoie le user" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())
      updated = Accounts.touch_last_chat_at(user)
      assert updated.last_chat_at != nil
    end
  end

  describe "push tokens" do
    test "register_push_token/2 ajoute un token sans doublon" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())

      {:ok, user} = Accounts.register_push_token(user, "tok-1")
      assert user.push_tokens == ["tok-1"]

      {:ok, user} = Accounts.register_push_token(user, "tok-1")
      assert user.push_tokens == ["tok-1"]

      {:ok, user} = Accounts.register_push_token(user, "tok-2")
      assert "tok-1" in user.push_tokens
      assert "tok-2" in user.push_tokens
    end

    test "unregister_push_token/2 retire un token" do
      {:ok, user} = Accounts.get_or_create_user(unique_email())
      {:ok, user} = Accounts.register_push_token(user, "tok-1")
      {:ok, user} = Accounts.register_push_token(user, "tok-2")

      {:ok, user} = Accounts.unregister_push_token(user, "tok-1")
      refute "tok-1" in user.push_tokens
      assert "tok-2" in user.push_tokens
    end
  end

  describe "magic links" do
    test "create_magic_link/2 retourne un token et un code en clair" do
      email = unique_email()
      assert {:ok, %{token: token, code: code}} = Accounts.create_magic_link(email)
      assert is_binary(token)
      assert is_binary(code)
    end

    test "consume_magic_link/1 crée/connecte l'utilisateur" do
      email = unique_email()
      {:ok, %{token: token}} = Accounts.create_magic_link(email)

      assert {:ok, %{user: user, joined_building: nil}} = Accounts.consume_magic_link(token)
      assert user.email == email
    end

    test "consume_magic_link/1 rejette un token inconnu" do
      assert {:error, :invalid_token} = Accounts.consume_magic_link("nope")
    end

    test "consume_magic_link/1 rejette un token déjà consommé" do
      email = unique_email()
      {:ok, %{token: token}} = Accounts.create_magic_link(email)
      {:ok, _} = Accounts.consume_magic_link(token)

      assert {:error, :invalid_token} = Accounts.consume_magic_link(token)
    end

    test "create_magic_link/2 invalide les liens actifs précédents pour le même email" do
      email = unique_email()
      {:ok, %{token: old_token}} = Accounts.create_magic_link(email)
      {:ok, %{token: new_token}} = Accounts.create_magic_link(email)

      assert {:error, :invalid_token} = Accounts.consume_magic_link(old_token)
      assert {:ok, %{user: _}} = Accounts.consume_magic_link(new_token)
    end

    test "consume_magic_code/2 avec un code valide connecte l'utilisateur" do
      email = unique_email()
      {:ok, %{code: code}} = Accounts.create_magic_link(email)

      assert {:ok, %{user: user}} = Accounts.consume_magic_code(email, code)
      assert user.email == email
    end

    test "consume_magic_code/2 rejette un mauvais code" do
      email = unique_email()
      {:ok, _} = Accounts.create_magic_link(email)

      assert {:error, :invalid_code} = Accounts.consume_magic_code(email, "000000")
    end

    test "consume_magic_code/2 rejette un email sans lien actif" do
      assert {:error, :invalid_code} =
               Accounts.consume_magic_code(unique_email("nolink"), "123456")
    end

    test "consume_magic_link/2 applique first_name/last_name sur un nouveau user" do
      email = unique_email()

      {:ok, %{token: token}} =
        Accounts.create_magic_link(email, first_name: "Bob", last_name: "Martin")

      assert {:ok, %{user: user}} = Accounts.consume_magic_link(token)
      assert user.first_name == "Bob"
      assert user.last_name == "Martin"
    end
  end
end
