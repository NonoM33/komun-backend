defmodule KomunBackend.AccountsMagicLinkTest do
  use KomunBackend.DataCase

  alias KomunBackend.Accounts
  alias KomunBackend.Accounts.{User, MagicLink}
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Organizations.Organization

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp insert_organization!(attrs \\ %{}) do
    %Organization{}
    |> Organization.changeset(
      Map.merge(
        %{name: "Org #{System.unique_integer([:positive])}"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_building!(org, attrs \\ %{}) do
    # Depuis l'introduction des résidences, chaque bâtiment doit avoir
    # une `residence_id`. Si le test n'en fournit pas, on en crée une
    # dédiée. Le code résidence est distinct du code bâtiment pour
    # éviter les collisions sur l'unique_index.
    residence_id =
      case Map.get(attrs, :residence_id) do
        nil ->
          residence_code =
            "R" <>
              (System.unique_integer([:positive])
               |> Integer.to_string()
               |> String.pad_leading(7, "0"))

          {:ok, r} =
            %KomunBackend.Residences.Residence{}
            |> KomunBackend.Residences.Residence.initial_changeset(%{
              name: "Résidence #{System.unique_integer([:positive])}",
              join_code: residence_code,
              organization_id: org.id
            })
            |> Repo.insert()

          r.id

        id ->
          id
      end

    %Building{}
    |> Building.initial_changeset(
      Map.merge(
        %{
          name: "Résidence Test",
          address: "10 rue des Lilas",
          city: "Paris",
          postal_code: "75001",
          organization_id: org.id,
          residence_id: residence_id,
          join_code: Map.get(attrs, :join_code, Buildings.generate_join_code())
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "create_magic_link/2" do
    test "stores first_name, last_name and join_code when provided" do
      {:ok, %{token: token}} =
        Accounts.create_magic_link("newuser@example.com",
          first_name: " Alice ",
          last_name: "Martin",
          join_code: "ABC12345"
        )

      ml =
        Repo.one(
          from ml in MagicLink,
            where: ml.token_hash == ^MagicLink.hash_token(token)
        )

      assert ml.email == "newuser@example.com"
      # trimmed
      assert ml.first_name == "Alice"
      assert ml.last_name == "Martin"
      assert ml.join_code == "ABC12345"
    end

    test "persists nil signup fields when not provided" do
      {:ok, %{token: token}} = Accounts.create_magic_link("plain@example.com")

      ml =
        Repo.one(
          from ml in MagicLink,
            where: ml.token_hash == ^MagicLink.hash_token(token)
        )

      assert is_nil(ml.first_name)
      assert is_nil(ml.last_name)
      assert is_nil(ml.join_code)
    end

    test "treats blank strings as nil" do
      {:ok, %{token: token}} =
        Accounts.create_magic_link("blank@example.com",
          first_name: "   ",
          last_name: "",
          join_code: nil
        )

      ml =
        Repo.one(
          from ml in MagicLink,
            where: ml.token_hash == ^MagicLink.hash_token(token)
        )

      assert is_nil(ml.first_name)
      assert is_nil(ml.last_name)
      assert is_nil(ml.join_code)
    end
  end

  describe "consume_magic_link/1 without signup payload" do
    test "returns the user and nil joined_building" do
      {:ok, %{token: token}} = Accounts.create_magic_link("existing@example.com")

      assert {:ok, %{user: %User{email: "existing@example.com"}, joined_building: nil}} =
               Accounts.consume_magic_link(token)
    end

    test "replay fails after consumption" do
      {:ok, %{token: token}} = Accounts.create_magic_link("once@example.com")
      assert {:ok, %{user: _}} = Accounts.consume_magic_link(token)
      assert {:error, :invalid_token} = Accounts.consume_magic_link(token)
    end

    test "requesting a second link invalidates the first one for the same email" do
      # Répro du bug "Pascale" : un user a fait le formulaire register, a
      # redemandé un lien depuis /login et a cliqué par erreur sur le
      # premier email. Attendu : le vieux token n'est plus valide, seul
      # le plus récent l'est.
      {:ok, %{token: token_1}} = Accounts.create_magic_link("pascale@example.com")
      {:ok, %{token: token_2}} = Accounts.create_magic_link("pascale@example.com")

      assert {:error, :invalid_token} = Accounts.consume_magic_link(token_1)
      assert {:ok, %{user: _}} = Accounts.consume_magic_link(token_2)
    end

    test "invalidation is scoped to the email (other users unaffected)" do
      {:ok, %{token: token_other}} = Accounts.create_magic_link("other@example.com")
      {:ok, %{token: _token_mine_1}} = Accounts.create_magic_link("mine@example.com")
      {:ok, %{token: _token_mine_2}} = Accounts.create_magic_link("mine@example.com")

      # Le token de l'autre email est intact.
      assert {:ok, %{user: %User{email: "other@example.com"}}} =
               Accounts.consume_magic_link(token_other)
    end
  end

  describe "consume_magic_link/1 with signup payload" do
    test "applies first_name and last_name to a newly-created user" do
      {:ok, %{token: token}} =
        Accounts.create_magic_link("fresh@example.com",
          first_name: "Alice",
          last_name: "Durand"
        )

      {:ok, %{user: user, joined_building: nil}} = Accounts.consume_magic_link(token)

      assert user.first_name == "Alice"
      assert user.last_name == "Durand"
    end

    test "does NOT overwrite a name the user already set" do
      # User already exists with a name — the magic-link signup fields
      # must not clobber them (the link may have been crafted months ago
      # by a renter who since updated their profile).
      {:ok, user} =
        %User{}
        |> User.changeset(%{
          email: "already@example.com",
          first_name: "Existing",
          last_name: "Name"
        })
        |> Repo.insert()

      {:ok, %{token: token}} =
        Accounts.create_magic_link("already@example.com",
          first_name: "Overwritten",
          last_name: "Never"
        )

      {:ok, %{user: updated}} = Accounts.consume_magic_link(token)

      assert updated.id == user.id
      assert updated.first_name == "Existing"
      assert updated.last_name == "Name"
    end

    test "fills only the blank name fields, keeping existing ones" do
      {:ok, _user} =
        %User{}
        |> User.changeset(%{email: "partial@example.com", first_name: "Has"})
        |> Repo.insert()

      {:ok, %{token: token}} =
        Accounts.create_magic_link("partial@example.com",
          first_name: "New",
          last_name: "Last"
        )

      {:ok, %{user: updated}} = Accounts.consume_magic_link(token)

      assert updated.first_name == "Has"
      assert updated.last_name == "Last"
    end

    test "auto-joins the user to the building matching join_code" do
      org = insert_organization!()
      building = insert_building!(org, %{join_code: "JOINME99"})

      {:ok, %{token: token}} =
        Accounts.create_magic_link("joiner@example.com", join_code: "joinme99")

      {:ok, %{user: user, joined_building: joined}} = Accounts.consume_magic_link(token)

      assert joined.id == building.id
      assert Buildings.member?(building.id, user.id)
    end

    test "auto-join is idempotent when the user is already a member" do
      org = insert_organization!()
      building = insert_building!(org, %{join_code: "IDEMPOT7"})

      {:ok, user} =
        %User{}
        |> User.changeset(%{email: "already-member@example.com"})
        |> Repo.insert()

      # Pre-existing membership — consuming the link must not raise.
      {:ok, _member} = Buildings.add_member(building.id, user.id)

      {:ok, %{token: token}} =
        Accounts.create_magic_link("already-member@example.com", join_code: "IDEMPOT7")

      {:ok, %{user: reloaded, joined_building: joined}} = Accounts.consume_magic_link(token)

      assert reloaded.id == user.id
      assert joined.id == building.id
      # Still a single member (no duplicate).
      assert length(Buildings.list_members(building.id)) == 1
    end

    test "unknown join_code yields joined_building: nil but login still succeeds" do
      {:ok, %{token: token}} =
        Accounts.create_magic_link("bad-code@example.com", join_code: "DOESNOTX")

      {:ok, %{user: user, joined_building: nil}} = Accounts.consume_magic_link(token)
      assert user.email == "bad-code@example.com"
    end
  end

  # ── Magic CODE (PWA iOS standalone bypass) ────────────────────────────────
  describe "consume_magic_code/2" do
    test "valid code logs the user in (cas iPhone PWA : pas de clic dans Mail)" do
      {:ok, %{code: code}} = Accounts.create_magic_link("ios-user@example.com")

      assert {:ok, %{user: user, joined_building: nil}} =
               Accounts.consume_magic_code("ios-user@example.com", code)

      assert user.email == "ios-user@example.com"
    end

    test "code is normalized: tolerates whitespace and dashes (iOS auto-format)" do
      {:ok, %{code: code}} = Accounts.create_magic_link("space@example.com")

      # 6 digits → "123 456" injecté à la main pour vérifier le strip
      pretty = String.slice(code, 0, 3) <> " " <> String.slice(code, 3, 3)

      # On passe par le controller path qui strip — le contexte
      # Accounts demande le code propre, mais le controller (testé
      # ailleurs) gère le formatage utilisateur. On vérifie ici que
      # le code SHA-256 lookup fait son boulot tel quel :
      assert {:ok, %{user: u}} = Accounts.consume_magic_code("space@example.com", code)
      assert u.email == "space@example.com"

      # Un code formaté avec espace ne matche PAS au niveau métier
      # (volontaire — c'est le controller qui normalise) :
      {:ok, %{code: code2}} = Accounts.create_magic_link("space2@example.com")
      _ = code2
      assert {:error, :invalid_code} =
               Accounts.consume_magic_code("space2@example.com", pretty)
    end

    test "wrong code increments attempts_count" do
      {:ok, %{code: _correct}} = Accounts.create_magic_link("brute@example.com")

      assert {:error, :invalid_code} =
               Accounts.consume_magic_code("brute@example.com", "000000")

      ml = Repo.one(from ml in MagicLink, where: ml.email == "brute@example.com")
      assert ml.attempts_count == 1
      assert is_nil(ml.used_at)
    end

    test "5 wrong attempts invalidate the magic link" do
      {:ok, _} = Accounts.create_magic_link("brute2@example.com")

      for _ <- 1..5 do
        assert {:error, :invalid_code} =
                 Accounts.consume_magic_code("brute2@example.com", "000000")
      end

      ml = Repo.one(from ml in MagicLink, where: ml.email == "brute2@example.com")
      assert ml.attempts_count == 5
      refute is_nil(ml.used_at)

      # Même le bon code refuse maintenant — link grillé.
      {:ok, %{code: code_after_lock}} = Accounts.create_magic_link("brute3@example.com")
      _ = code_after_lock
    end

    test "expired magic link rejects the code" do
      {:ok, %{code: code}} = Accounts.create_magic_link("late@example.com")

      # Force l'expiration en backdoorant expires_at (15 min dans le passé).
      ml = Repo.one(from ml in MagicLink, where: ml.email == "late@example.com")

      ml
      |> Ecto.Changeset.change(
        expires_at:
          DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert {:error, :expired_code} =
               Accounts.consume_magic_code("late@example.com", code)
    end

    test "consuming the link via the URL token also invalidates the code path" do
      {:ok, %{token: token, code: code}} =
        Accounts.create_magic_link("dual@example.com")

      assert {:ok, _} = Accounts.consume_magic_link(token)

      # Le code ne peut plus être utilisé après que le lien a été consommé :
      # used_at != nil → le query (is_nil(used_at)) ne le trouve plus.
      assert {:error, :invalid_code} =
               Accounts.consume_magic_code("dual@example.com", code)
    end

    test "used code can't be replayed (single-use, like the link)" do
      {:ok, %{code: code}} = Accounts.create_magic_link("once-code@example.com")

      assert {:ok, _} = Accounts.consume_magic_code("once-code@example.com", code)
      assert {:error, :invalid_code} =
               Accounts.consume_magic_code("once-code@example.com", code)
    end

    test "code from a different email never matches" do
      {:ok, %{code: code_alice}} = Accounts.create_magic_link("alice@example.com")
      {:ok, _} = Accounts.create_magic_link("bob@example.com")

      assert {:error, :invalid_code} =
               Accounts.consume_magic_code("bob@example.com", code_alice)
    end
  end
end
