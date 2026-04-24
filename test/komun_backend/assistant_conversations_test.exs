defmodule KomunBackend.AssistantConversationsTest do
  @moduledoc """
  Non-regression suite for the multi-conversation API.

  Context: the `web_v2` frontend was shipped calling
  `/buildings/:id/assistant/conversations[...]` while the backend still
  only had the legacy `/assistant/ask` endpoint — every ask in prod
  surfaced as "Impossible de contacter l'assistant.". These tests lock
  the contract for each new endpoint so the outage can't reappear.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Assistant, Buildings, Repo}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Assistant.Conversation
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Residences.Residence

  defp insert_user!(attrs \\ %{}) do
    defaults = %{
      email: "user-#{System.unique_integer([:positive])}@example.com",
      first_name: "T",
      role: :coproprietaire
    }

    %User{}
    |> User.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_building!(code \\ nil) do
    # We insert via struct literals (not changesets) because the changeset
    # surface for Residence / Building differs across branches (stg has
    # `initial_changeset/2`, main doesn't). A struct insert hits the DB
    # directly and is stable regardless of which branch's code is loaded.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    org_suffix = System.unique_integer([:positive])

    {:ok, org} =
      Repo.insert(%Organization{
        name: "Org #{org_suffix}",
        slug: "org-#{org_suffix}",
        inserted_at: now,
        updated_at: now
      })

    residence_code =
      "R" <>
        (System.unique_integer([:positive])
         |> Integer.to_string()
         |> String.pad_leading(7, "0"))

    {:ok, residence} =
      Repo.insert(%Residence{
        name: "Résidence #{residence_code}",
        slug: "residence-#{String.downcase(residence_code)}",
        join_code: residence_code,
        is_active: true,
        inserted_at: now,
        updated_at: now
      })

    building_code =
      code ||
        "B" <>
          (System.unique_integer([:positive])
           |> Integer.to_string()
           |> String.pad_leading(7, "0"))

    Repo.insert!(%Building{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "10 rue X",
      city: "Paris",
      postal_code: "75001",
      country: "FR",
      is_active: true,
      organization_id: org.id,
      residence_id: residence.id,
      join_code: building_code,
      inserted_at: now,
      updated_at: now
    })
  end

  defp add_member!(building, user) do
    {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)
    :ok
  end

  describe "create_conversation/3" do
    test "fails with :not_a_member when user isn't in the building" do
      user = insert_user!()
      building = insert_building!()

      assert {:error, :not_a_member} = Assistant.create_conversation(user, building.id)
    end

    test "creates a conversation for a member, with a default title" do
      user = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, user)

      assert {:ok, conv} = Assistant.create_conversation(user, building.id)
      assert conv.user_id == user.id
      assert conv.building_id == building.id
      assert conv.title == "Nouvelle conversation"
      assert conv.message_count == 0
    end
  end

  describe "list_conversations/2" do
    test "returns only the caller's conversations in this building, newest first" do
      user = insert_user!()
      other_user = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, user)
      :ok = add_member!(building, other_user)

      {:ok, _older} = Assistant.create_conversation(user, building.id)
      {:ok, _foreign} = Assistant.create_conversation(other_user, building.id)
      Process.sleep(1_100)
      {:ok, newer} = Assistant.create_conversation(user, building.id)

      ids = Assistant.list_conversations(user.id, building.id) |> Enum.map(& &1.id)

      # Foreign convo filtered out.
      assert length(ids) == 2
      # Newest first.
      assert hd(ids) == newer.id
    end
  end

  describe "get_conversation/3" do
    test "returns :not_found when the conversation belongs to someone else" do
      mine = insert_user!()
      other = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, mine)
      :ok = add_member!(building, other)

      {:ok, conv} = Assistant.create_conversation(other, building.id)

      assert {:error, :not_found} =
               Assistant.get_conversation(mine.id, building.id, conv.id)
    end

    test "returns the conversation with an (initially empty) messages list" do
      user = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, user)

      {:ok, conv} = Assistant.create_conversation(user, building.id)

      assert {:ok, loaded} = Assistant.get_conversation(user.id, building.id, conv.id)
      assert loaded.id == conv.id
      assert loaded.messages == []
    end
  end

  describe "delete_conversation/3" do
    test "deletes a conversation the user owns" do
      user = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, user)

      {:ok, conv} = Assistant.create_conversation(user, building.id)

      assert :ok = Assistant.delete_conversation(user.id, building.id, conv.id)
      refute Repo.get(Conversation, conv.id)
    end

    test "refuses to delete someone else's conversation" do
      owner = insert_user!()
      attacker = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, owner)
      :ok = add_member!(building, attacker)

      {:ok, conv} = Assistant.create_conversation(owner, building.id)

      assert {:error, :not_found} =
               Assistant.delete_conversation(attacker.id, building.id, conv.id)

      assert Repo.get(Conversation, conv.id)
    end
  end

  describe "ask_in_conversation/4 (no Groq key)" do
    # GROQ_API_KEY is absent in test env, so `AI.Groq.complete/1` short-circuits
    # to {:error, :missing_api_key}. That lets us exercise every auth / routing
    # branch without hitting the network — which is the whole point, since the
    # original prod outage never reached Groq anyway.

    test "rejects an empty question with :empty_question" do
      user = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, user)
      {:ok, conv} = Assistant.create_conversation(user, building.id)

      assert {:error, :empty_question} =
               Assistant.ask_in_conversation(user, building.id, conv.id, "")

      assert {:error, :empty_question} =
               Assistant.ask_in_conversation(user, building.id, conv.id, "   ")
    end

    test "returns :not_a_member when the user isn't in the building" do
      user = insert_user!()
      building = insert_building!()
      # no add_member!
      {:error, :not_a_member} =
        Assistant.ask_in_conversation(user, building.id, Ecto.UUID.generate(), "bonjour")
    end

    test "returns :not_found when the conversation id doesn't belong to the user" do
      owner = insert_user!()
      attacker = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, owner)
      :ok = add_member!(building, attacker)

      {:ok, conv} = Assistant.create_conversation(owner, building.id)

      assert {:error, :not_found} =
               Assistant.ask_in_conversation(attacker, building.id, conv.id, "hello")
    end

    test "returns :not_found when the conversation id is a random UUID" do
      user = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, user)

      assert {:error, :not_found} =
               Assistant.ask_in_conversation(
                 user,
                 building.id,
                 Ecto.UUID.generate(),
                 "bonjour"
               )
    end

    test "returns :missing_api_key once membership + conversation ownership are OK" do
      # This is the key check: before the fix, this flow was a 404 at the
      # router, not a clean domain error. Now we reach Groq's short-circuit.
      user = insert_user!()
      building = insert_building!()
      :ok = add_member!(building, user)
      {:ok, conv} = Assistant.create_conversation(user, building.id)

      assert {:error, :missing_api_key} =
               Assistant.ask_in_conversation(
                 user,
                 building.id,
                 conv.id,
                 "Les chiens sont-ils autorisés ?"
               )
    end
  end
end
