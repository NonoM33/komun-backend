defmodule KomunBackend.ChannelsTest do
  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Accounts, Buildings, Channels}
  alias KomunBackend.Channels.Channel

  defp insert_building!(attrs \\ %{}) do
    defaults = %{
      "name" => "Bâtiment #{System.unique_integer([:positive])}",
      "address" => "3 rue des Lilas",
      "city" => "Paris",
      "postal_code" => "75015"
    }

    {:ok, building} = Buildings.create_building(Map.merge(defaults, attrs))
    building
  end

  defp insert_user! do
    {:ok, user} =
      Accounts.get_or_create_user("chan-#{System.unique_integer([:positive])}@komun.app")

    user
  end

  describe "create_channel/3" do
    test "crée un canal avec les valeurs par défaut" do
      building = insert_building!()
      user = insert_user!()

      assert {:ok, %Channel{} = channel} =
               Channels.create_channel(building.id, user.id, %{"name" => "Général"})

      assert channel.name == "Général"
      assert channel.building_id == building.id
      assert channel.created_by_id == user.id
      assert channel.visibility == "public"
      assert channel.is_readonly == false
    end

    test "accepte des clés atomes (normalisation)" do
      building = insert_building!()
      user = insert_user!()

      assert {:ok, channel} =
               Channels.create_channel(building.id, user.id, %{name: "Travaux"})

      assert channel.name == "Travaux"
    end

    test "rejette un canal sans nom" do
      building = insert_building!()
      user = insert_user!()

      assert {:error, cs} = Channels.create_channel(building.id, user.id, %{"name" => ""})
      assert %{name: _} = errors_on(cs)
    end

    test "rejette un nom trop long" do
      building = insert_building!()
      user = insert_user!()

      long = String.duplicate("x", 81)
      assert {:error, cs} = Channels.create_channel(building.id, user.id, %{"name" => long})
      assert %{name: _} = errors_on(cs)
    end

    test "rejette une visibilité invalide" do
      building = insert_building!()
      user = insert_user!()

      assert {:error, cs} =
               Channels.create_channel(building.id, user.id, %{
                 "name" => "X",
                 "visibility" => "top_secret"
               })

      assert %{visibility: _} = errors_on(cs)
    end

    test "rejette un doublon de nom dans le même bâtiment" do
      building = insert_building!()
      user = insert_user!()

      {:ok, _} = Channels.create_channel(building.id, user.id, %{"name" => "Général"})

      assert {:error, cs} =
               Channels.create_channel(building.id, user.id, %{"name" => "Général"})

      # La contrainte d'unicité porte sur [:building_id, :name] ; Ecto
      # rattache l'erreur au premier champ de l'index (building_id).
      assert %{building_id: _} = errors_on(cs)
    end

    test "autorise le même nom dans deux bâtiments différents" do
      b1 = insert_building!()
      b2 = insert_building!()
      user = insert_user!()

      assert {:ok, _} = Channels.create_channel(b1.id, user.id, %{"name" => "Général"})
      assert {:ok, _} = Channels.create_channel(b2.id, user.id, %{"name" => "Général"})
    end
  end

  describe "list_channels/1" do
    test "remonte les canaux d'un bâtiment" do
      building = insert_building!()
      user = insert_user!()

      {:ok, c1} = Channels.create_channel(building.id, user.id, %{"name" => "Premier"})
      {:ok, c2} = Channels.create_channel(building.id, user.id, %{"name" => "Second"})

      ids = Channels.list_channels(building.id) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([c1.id, c2.id])
    end

    test "isole les canaux par bâtiment" do
      b1 = insert_building!()
      b2 = insert_building!()
      user = insert_user!()

      {:ok, c1} = Channels.create_channel(b1.id, user.id, %{"name" => "Chez B1"})
      {:ok, _} = Channels.create_channel(b2.id, user.id, %{"name" => "Chez B2"})

      ids = Channels.list_channels(b1.id) |> Enum.map(& &1.id)
      assert ids == [c1.id]
    end
  end

  describe "get_channel/1 et get_channel!/1" do
    test "get_channel/1 retourne le canal ou nil" do
      building = insert_building!()
      user = insert_user!()
      {:ok, channel} = Channels.create_channel(building.id, user.id, %{"name" => "X"})

      assert Channels.get_channel(channel.id).id == channel.id
      assert Channels.get_channel(Ecto.UUID.generate()) == nil
    end

    test "get_channel!/1 lève pour un id inconnu" do
      assert_raise Ecto.NoResultsError, fn ->
        Channels.get_channel!(Ecto.UUID.generate())
      end
    end
  end

  describe "update_channel/2" do
    test "met à jour les champs" do
      building = insert_building!()
      user = insert_user!()
      {:ok, channel} = Channels.create_channel(building.id, user.id, %{"name" => "X"})

      assert {:ok, updated} =
               Channels.update_channel(channel, %{"description" => "Un canal de test"})

      assert updated.description == "Un canal de test"
    end

    test "rejette une mise à jour invalide" do
      building = insert_building!()
      user = insert_user!()
      {:ok, channel} = Channels.create_channel(building.id, user.id, %{"name" => "X"})

      assert {:error, cs} = Channels.update_channel(channel, %{"name" => ""})
      assert %{name: _} = errors_on(cs)
    end
  end

  describe "delete_channel/1" do
    test "supprime un canal" do
      building = insert_building!()
      user = insert_user!()
      {:ok, channel} = Channels.create_channel(building.id, user.id, %{"name" => "X"})

      assert {:ok, _} = Channels.delete_channel(channel)
      assert Channels.get_channel(channel.id) == nil
    end
  end

  describe "manager_roles/0" do
    test "liste les rôles autorisés à gérer les canaux" do
      roles = Channels.manager_roles()
      assert :super_admin in roles
      assert :president_cs in roles
      refute :coproprietaire in roles
    end
  end
end
