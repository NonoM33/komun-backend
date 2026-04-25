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
      {:ok, token} =
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
      {:ok, token} = Accounts.create_magic_link("plain@example.com")

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
      {:ok, token} =
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
      {:ok, token} = Accounts.create_magic_link("existing@example.com")

      assert {:ok, %{user: %User{email: "existing@example.com"}, joined_building: nil}} =
               Accounts.consume_magic_link(token)
    end

    test "replay fails after consumption" do
      {:ok, token} = Accounts.create_magic_link("once@example.com")
      assert {:ok, %{user: _}} = Accounts.consume_magic_link(token)
      assert {:error, :invalid_token} = Accounts.consume_magic_link(token)
    end

    test "requesting a second link invalidates the first one for the same email" do
      # Répro du bug "Pascale" : un user a fait le formulaire register, a
      # redemandé un lien depuis /login et a cliqué par erreur sur le
      # premier email. Attendu : le vieux token n'est plus valide, seul
      # le plus récent l'est.
      {:ok, token_1} = Accounts.create_magic_link("pascale@example.com")
      {:ok, token_2} = Accounts.create_magic_link("pascale@example.com")

      assert {:error, :invalid_token} = Accounts.consume_magic_link(token_1)
      assert {:ok, %{user: _}} = Accounts.consume_magic_link(token_2)
    end

    test "invalidation is scoped to the email (other users unaffected)" do
      {:ok, token_other} = Accounts.create_magic_link("other@example.com")
      {:ok, _token_mine_1} = Accounts.create_magic_link("mine@example.com")
      {:ok, _token_mine_2} = Accounts.create_magic_link("mine@example.com")

      # Le token de l'autre email est intact.
      assert {:ok, %{user: %User{email: "other@example.com"}}} =
               Accounts.consume_magic_link(token_other)
    end
  end

  describe "consume_magic_link/1 with signup payload" do
    test "applies first_name and last_name to a newly-created user" do
      {:ok, token} =
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

      {:ok, token} =
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

      {:ok, token} =
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

      {:ok, token} =
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

      {:ok, token} =
        Accounts.create_magic_link("already-member@example.com", join_code: "IDEMPOT7")

      {:ok, %{user: reloaded, joined_building: joined}} = Accounts.consume_magic_link(token)

      assert reloaded.id == user.id
      assert joined.id == building.id
      # Still a single member (no duplicate).
      assert length(Buildings.list_members(building.id)) == 1
    end

    test "unknown join_code yields joined_building: nil but login still succeeds" do
      {:ok, token} =
        Accounts.create_magic_link("bad-code@example.com", join_code: "DOESNOTX")

      {:ok, %{user: user, joined_building: nil}} = Accounts.consume_magic_link(token)
      assert user.email == "bad-code@example.com"
    end
  end
end
