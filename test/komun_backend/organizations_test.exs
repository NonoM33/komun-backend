defmodule KomunBackend.OrganizationsTest do
  @moduledoc """
  TICKET-2.3 — Tests du context `KomunBackend.Organizations` :
  fonction `list_for_staff/1` (pagination, filtres, tri).
  """

  use KomunBackend.DataCase, async: false

  import Ecto.Query

  alias KomunBackend.Organizations
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Repo

  defp insert_org!(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert!()
  end

  describe "list_for_staff/1" do
    test "renvoie toutes les orgs avec pagination par défaut (page=1, per_page=25)" do
      _o1 = insert_org!(%{name: "Alpha SCI"})
      _o2 = insert_org!(%{name: "Beta Syndic"})
      _o3 = insert_org!(%{name: "Gamma Coproprietes"})

      result = Organizations.list_for_staff(%{})

      assert length(result.entries) == 3
      assert result.meta.page == 1
      assert result.meta.per_page == 25
      assert result.meta.total == 3
    end

    test "tri par défaut : created_at desc (plus récent en premier)" do
      _old = insert_org!(%{name: "Old Org"})
      :timer.sleep(1100)
      _new = insert_org!(%{name: "New Org"})

      result = Organizations.list_for_staff(%{})

      assert hd(result.entries).name == "New Org"
    end

    test "filtre par plan" do
      free = insert_org!(%{name: "Free One"})
      pro = insert_org!(%{name: "Pro One"})

      # On force le plan au repo (changeset standard ne le cast pas en update,
      # mais à la création par défaut c'est :free — donc on update via SQL).
      Repo.update_all(
        from(o in Organization, where: o.id == ^pro.id),
        set: [subscription_plan: :pro]
      )

      result = Organizations.list_for_staff(%{plan: :pro})
      assert length(result.entries) == 1
      assert hd(result.entries).id == pro.id

      result = Organizations.list_for_staff(%{plan: :free})
      assert length(result.entries) == 1
      assert hd(result.entries).id == free.id
    end

    test "filtre par recherche q (insensible à la casse, partiel)" do
      a = insert_org!(%{name: "Résidence des Tilleuls"})
      _b = insert_org!(%{name: "Le Clos Saint-Michel"})

      result = Organizations.list_for_staff(%{q: "tilleuls"})
      assert length(result.entries) == 1
      assert hd(result.entries).id == a.id

      result = Organizations.list_for_staff(%{q: "TILLEULS"})
      assert length(result.entries) == 1

      result = Organizations.list_for_staff(%{q: "inexistant"})
      assert result.entries == []
    end

    test "filtre par is_active (suspension)" do
      active = insert_org!(%{name: "Active SCI"})
      _suspended = insert_org!(%{name: "Suspended SCI"})

      Repo.update_all(
        from(o in Organization, where: o.name == "Suspended SCI"),
        set: [is_active: false]
      )

      result = Organizations.list_for_staff(%{is_active: true})
      assert length(result.entries) == 1
      assert hd(result.entries).id == active.id

      result = Organizations.list_for_staff(%{is_active: false})
      assert length(result.entries) == 1
    end

    test "pagination — page 2 avec per_page=2 sur 3 orgs" do
      insert_org!(%{name: "P1"})
      insert_org!(%{name: "P2"})
      insert_org!(%{name: "P3"})

      page1 = Organizations.list_for_staff(%{page: 1, per_page: 2})
      page2 = Organizations.list_for_staff(%{page: 2, per_page: 2})

      assert length(page1.entries) == 2
      assert length(page2.entries) == 1
      assert page1.meta.total == 3
      assert page2.meta.page == 2
    end

    test "per_page est clampé entre 1 et 100" do
      insert_org!(%{name: "Solo"})

      result = Organizations.list_for_staff(%{per_page: 9999})
      assert result.meta.per_page == 100

      result = Organizations.list_for_staff(%{per_page: 0})
      assert result.meta.per_page == 1
    end

    test "page > total → entries vides, pas d'erreur 404" do
      insert_org!(%{name: "Solo"})

      result = Organizations.list_for_staff(%{page: 99, per_page: 25})

      assert result.entries == []
      assert result.meta.page == 99
      assert result.meta.total == 1
    end
  end
end
