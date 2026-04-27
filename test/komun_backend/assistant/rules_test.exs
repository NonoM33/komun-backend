defmodule KomunBackend.Assistant.RulesTest do
  @moduledoc """
  Unit tests for the prompt-assembly logic. We don't hit the database here:
  `build_system_prompt/2` is purely functional and is the only place where
  a regression could silently change every assistant answer in production.
  """

  use ExUnit.Case, async: true

  alias KomunBackend.Assistant.{Rule, Rules}

  describe "build_system_prompt/2" do
    test "returns the base prompt unchanged when there are no rules" do
      base = "BASE PROMPT"
      assert Rules.build_system_prompt(base, []) == base
    end

    test "appends an explicit overrides block listing the rules in order" do
      base = "BASE PROMPT"

      rules = [
        %Rule{content: "Si une activité gène un voisin, c'est interdit.", position: 0},
        %Rule{content: "Toujours conseiller de saisir le syndic.", position: 1}
      ]

      result = Rules.build_system_prompt(base, rules)

      assert String.starts_with?(result, "BASE PROMPT")

      assert result =~ "Règles spécifiques à cette résidence"

      # Bullets must appear in the order we received them.
      first_idx = :binary.match(result, "Si une activité gène un voisin") |> elem(0)
      second_idx = :binary.match(result, "Toujours conseiller de saisir") |> elem(0)
      assert first_idx < second_idx
    end

    test "uses '- ' bullets so the LLM treats them as a list" do
      result =
        Rules.build_system_prompt("base", [
          %Rule{content: "rule one"}
        ])

      assert result =~ "\n- rule one"
    end
  end

  describe "Rule.changeset/2" do
    test "trims whitespace and rejects empty content" do
      cs = Rule.changeset(%Rule{}, %{"content" => "   ", "building_id" => Ecto.UUID.generate()})
      refute cs.valid?
      assert {_msg, _} = cs.errors[:content] || cs.errors[:content]
    end

    test "rejects content over the max length" do
      too_long = String.duplicate("a", Rule.max_content_length() + 1)

      cs =
        Rule.changeset(%Rule{}, %{
          "content" => too_long,
          "building_id" => Ecto.UUID.generate()
        })

      refute cs.valid?
      assert cs.errors[:content]
    end

    test "accepts a normal short rule" do
      cs =
        Rule.changeset(%Rule{}, %{
          "content" => "Si ça gène un voisin, c'est interdit.",
          "building_id" => Ecto.UUID.generate()
        })

      assert cs.valid?
    end
  end
end
