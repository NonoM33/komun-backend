defmodule KomunBackend.BuildingsMembersTest do
  @moduledoc """
  Régression du bug "rôles disparus au redéploiement" (avril 2026).

  Avant la correction :
  - `Buildings.add_member/3` faisait un upsert avec
    `on_conflict: {:replace, [:role, :is_active, :joined_at, :updated_at]}`
    → écrasait silencieusement le rôle d'un membre existant si un caller
    rappelait `add_member` avec le default `:coproprietaire`.
  - `Buildings.join_by_code/3` se contentait de `member?` (filtré sur
    `is_active == true`) → si jamais une ligne `is_active: false` traînait
    en DB, `add_member` était rappelé avec le default → idem rôle écrasé.

  Ces tests gèlent la **nouvelle** sémantique :
  - `add_member` est strictement insertif (`{:error, :already_member}`),
  - `set_member_role` est l'**unique** chemin pour modifier un rôle,
  - `join_by_code` réactive un membre désactivé sans toucher au rôle,
  - chaque mutation est tracée dans `role_audit_log`.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Residences}
  alias KomunBackend.Audit.RoleAuditEntry
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.{Building, BuildingMember}
  alias KomunBackend.Residences.Residence

  defp insert_residence! do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "Résidence #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence, attrs \\ %{}) do
    defaults = %{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "2 rue des Lilas",
      city: "Paris",
      postal_code: "75015",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    }

    %Building{}
    |> Building.initial_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_user!(role \\ :coproprietaire) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp audit_entries(user_id, building_id) do
    Repo.all(
      from(e in RoleAuditEntry,
        where: e.user_id == ^user_id and e.building_id == ^building_id,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  describe "add_member/4 (insertion stricte)" do
    test "insère un nouveau membre et trace dans role_audit_log" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      assert {:ok, member} =
               Buildings.add_member(building.id, user.id, :membre_cs, source: :admin_panel)

      assert member.role == :membre_cs
      assert member.is_active == true

      assert [entry] = audit_entries(user.id, building.id)
      assert entry.scope == "building"
      assert entry.source == "admin_panel"
      assert entry.old_role == nil
      assert entry.new_role == "membre_cs"
    end

    test "refuse l'ajout d'un membre déjà présent et NE TOUCHE PAS au rôle" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      {:ok, _} = Buildings.add_member(building.id, user.id, :president_cs)

      # Bug avant le fix : ce 2e add_member écrasait :president_cs en
      # :coproprietaire. Maintenant on doit retourner :already_member et
      # garder le rôle existant.
      assert {:error, :already_member} =
               Buildings.add_member(building.id, user.id, :coproprietaire)

      assert %BuildingMember{role: :president_cs} =
               Repo.get_by(BuildingMember, building_id: building.id, user_id: user.id)
    end

    test "refuse même si la ligne existante est is_active: false" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      {:ok, member} = Buildings.add_member(building.id, user.id, :gardien)

      member
      |> Ecto.Changeset.change(is_active: false)
      |> Repo.update!()

      assert {:error, :already_member} =
               Buildings.add_member(building.id, user.id, :coproprietaire)

      reloaded = Repo.get_by(BuildingMember, building_id: building.id, user_id: user.id)
      assert reloaded.role == :gardien
      assert reloaded.is_active == false
    end
  end

  describe "set_member_role/4" do
    test "met à jour le rôle d'un membre existant et trace l'ancien/nouveau" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      assert {:ok, updated} =
               Buildings.set_member_role(building.id, user.id, :membre_cs,
                 source: :admin_panel,
                 actor_id: user.id
               )

      assert updated.role == :membre_cs

      [_creation, mutation] = audit_entries(user.id, building.id)
      assert mutation.scope == "building"
      assert mutation.source == "admin_panel"
      assert mutation.old_role == "coproprietaire"
      assert mutation.new_role == "membre_cs"
      assert mutation.actor_id == user.id
    end

    test "refuse {:error, :not_found} si la ligne n'existe pas" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      assert {:error, :not_found} =
               Buildings.set_member_role(building.id, user.id, :membre_cs)
    end

    test "réactive automatiquement une ligne is_active: false" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      {:ok, m} = Buildings.add_member(building.id, user.id, :gardien)

      m
      |> Ecto.Changeset.change(is_active: false)
      |> Repo.update!()

      assert {:ok, updated} =
               Buildings.set_member_role(building.id, user.id, :membre_cs)

      assert updated.is_active == true
      assert updated.role == :membre_cs
    end
  end

  describe "join_by_code/3 — préservation du rôle (cœur du bug)" do
    test "user déjà membre actif : ne change ni le rôle ni n'ajoute d'audit" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      {:ok, _} = Buildings.add_member(building.id, user.id, :membre_cs)

      assert {:ok, {:already_member, ^building}} =
               Buildings.join_by_code(building.join_code, user.id, :coproprietaire)

      assert %BuildingMember{role: :membre_cs} =
               Repo.get_by(BuildingMember, building_id: building.id, user_id: user.id)

      # 1 audit entry pour l'ajout initial, aucune pour le rejoin.
      assert length(audit_entries(user.id, building.id)) == 1
    end

    test "user soft-désactivé : réactive et garde son rôle d'origine" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      {:ok, m} = Buildings.add_member(building.id, user.id, :president_cs)

      m
      |> Ecto.Changeset.change(is_active: false)
      |> Repo.update!()

      # join_by_code passe par la branche reactivate. AVANT le fix,
      # `member?` retournait false (filtre is_active=true) et add_member
      # ré-écrivait le rôle avec :coproprietaire (default du caller).
      assert {:ok, {:already_member, ^building}} =
               Buildings.join_by_code(building.join_code, user.id, :coproprietaire)

      reloaded = Repo.get_by(BuildingMember, building_id: building.id, user_id: user.id)
      assert reloaded.role == :president_cs
      assert reloaded.is_active == true

      # On a 2 entrées : la création initiale + une trace de réactivation.
      [_creation, reactivation] = audit_entries(user.id, building.id)
      assert reactivation.source == "join_by_code"
      assert reactivation.metadata["reactivated"] == true
    end

    test "nouvel user : insère et trace avec source=join_by_code" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      assert {:ok, {^building, member}} =
               Buildings.join_by_code(building.join_code, user.id, :coproprietaire)

      assert member.role == :coproprietaire

      assert [entry] = audit_entries(user.id, building.id)
      assert entry.source == "join_by_code"
      assert entry.old_role == nil
      assert entry.new_role == "coproprietaire"
    end
  end

  describe "remove_member/3" do
    test "supprime la ligne et trace l'ancien rôle" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      {:ok, _} = Buildings.add_member(building.id, user.id, :membre_cs)

      assert {:ok, _} =
               Buildings.remove_member(building.id, user.id, source: :admin_panel)

      assert nil ==
               Repo.get_by(BuildingMember, building_id: building.id, user_id: user.id)

      [_creation, deletion] = audit_entries(user.id, building.id)
      assert deletion.old_role == "membre_cs"
      assert deletion.new_role == nil
    end
  end
end
