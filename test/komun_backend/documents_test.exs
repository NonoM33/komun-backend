defmodule KomunBackend.DocumentsTest do
  use ExUnit.Case, async: true

  alias KomunBackend.Documents.Document

  describe "Document.mandatory_categories/0" do
    test "includes :reglement so the frontend banner fires for empty residences" do
      cats = Document.mandatory_categories()
      assert :reglement in cats
    end
  end

  describe "Document.changeset/2" do
    test "auto-pins a newly-uploaded règlement" do
      cs =
        Document.changeset(%Document{}, %{
          title: "Règlement 2024",
          building_id: Ecto.UUID.generate(),
          category: :reglement
        })

      assert Ecto.Changeset.get_field(cs, :is_pinned) == true
    end

    test "does not force-pin other categories" do
      cs =
        Document.changeset(%Document{}, %{
          title: "PV AG 2024",
          building_id: Ecto.UUID.generate(),
          category: :pv_ag
        })

      assert Ecto.Changeset.get_field(cs, :is_pinned) == false
    end

    test "respects an explicit is_pinned: false on a règlement upload" do
      cs =
        Document.changeset(%Document{}, %{
          title: "Règlement draft",
          building_id: Ecto.UUID.generate(),
          category: :reglement,
          is_pinned: false
        })

      assert Ecto.Changeset.get_field(cs, :is_pinned) == false
    end

    test "rejects the changeset without a title" do
      cs =
        Document.changeset(%Document{}, %{
          building_id: Ecto.UUID.generate(),
          category: :reglement
        })

      refute cs.valid?
      assert %{title: ["can't be blank"]} = errors_on(cs)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
