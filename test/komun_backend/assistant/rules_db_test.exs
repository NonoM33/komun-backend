defmodule KomunBackend.Assistant.RulesDBTest do
  @moduledoc """
  DB-backed tests for the rules CRUD. Mirrors the structure used in
  `assistant_conversations_test.exs` to keep building/user setup
  consistent across branches.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.Assistant.{Rule, Rules}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Repo
  alias KomunBackend.Residences.Residence

  defp insert_user! do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %User{}
    |> User.changeset(%{
      email: "u-#{System.unique_integer([:positive])}@example.com",
      first_name: "T",
      role: :super_admin
    })
    |> Repo.insert!()
    |> tap(fn _ -> now end)
  end

  defp insert_building! do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    suffix = System.unique_integer([:positive])

    {:ok, org} =
      Repo.insert(%Organization{
        name: "Org #{suffix}",
        slug: "org-#{suffix}",
        inserted_at: now,
        updated_at: now
      })

    code =
      "R" <>
        (System.unique_integer([:positive])
         |> Integer.to_string()
         |> String.pad_leading(7, "0"))

    {:ok, residence} =
      Repo.insert(%Residence{
        name: "Résidence #{code}",
        slug: "residence-#{String.downcase(code)}",
        join_code: code,
        is_active: true,
        inserted_at: now,
        updated_at: now
      })

    bcode =
      "B" <>
        (System.unique_integer([:positive])
         |> Integer.to_string()
         |> String.pad_leading(7, "0"))

    Repo.insert!(%Building{
      name: "Bâtiment #{suffix}",
      address: "10 rue X",
      city: "Paris",
      postal_code: "75001",
      country: "FR",
      is_active: true,
      organization_id: org.id,
      residence_id: residence.id,
      join_code: bcode,
      inserted_at: now,
      updated_at: now
    })
  end

  describe "create_rule/3 + list_rules/1" do
    test "auto-positions new rules at the end" do
      user = insert_user!()
      b = insert_building!()

      {:ok, r1} = Rules.create_rule(b.id, user.id, %{"content" => "rule one"})
      {:ok, r2} = Rules.create_rule(b.id, user.id, %{"content" => "rule two"})

      assert r1.position == 0
      assert r2.position == 1

      assert [%Rule{id: id1}, %Rule{id: id2}] = Rules.list_rules(b.id)
      assert id1 == r1.id
      assert id2 == r2.id
    end

    test "rejects empty content" do
      user = insert_user!()
      b = insert_building!()

      assert {:error, cs} = Rules.create_rule(b.id, user.id, %{"content" => "   "})
      refute cs.valid?
    end
  end

  describe "list_active_rules/1" do
    test "skips disabled rules but keeps them in list_rules/1" do
      user = insert_user!()
      b = insert_building!()

      {:ok, _r1} = Rules.create_rule(b.id, user.id, %{"content" => "active rule"})

      {:ok, r2} =
        Rules.create_rule(b.id, user.id, %{"content" => "disabled rule", "enabled" => false})

      assert length(Rules.list_rules(b.id)) == 2
      active = Rules.list_active_rules(b.id)
      assert length(active) == 1
      refute Enum.any?(active, &(&1.id == r2.id))
    end
  end

  describe "update_rule/2 + delete_rule/1" do
    test "update_rule rewrites the content and toggles enabled" do
      user = insert_user!()
      b = insert_building!()
      {:ok, r} = Rules.create_rule(b.id, user.id, %{"content" => "old wording"})

      {:ok, updated} =
        Rules.update_rule(r, %{"content" => "new wording", "enabled" => false})

      assert updated.content == "new wording"
      refute updated.enabled
    end

    test "delete_rule removes the row" do
      user = insert_user!()
      b = insert_building!()
      {:ok, r} = Rules.create_rule(b.id, user.id, %{"content" => "doomed"})

      assert {:ok, _} = Rules.delete_rule(r)
      assert {:error, :not_found} = Rules.get_rule(r.id)
    end
  end

  describe "get_rule/1 with bad input" do
    test "returns :not_found instead of crashing on a non-uuid string" do
      assert {:error, :not_found} = Rules.get_rule("not-a-uuid")
    end
  end
end
