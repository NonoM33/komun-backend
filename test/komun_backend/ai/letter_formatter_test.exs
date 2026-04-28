defmodule KomunBackend.AI.LetterFormatterTest do
  use ExUnit.Case, async: true

  alias KomunBackend.AI.LetterFormatter

  describe "to_plain_text/1" do
    test "strippe le gras `**...**`" do
      assert LetterFormatter.to_plain_text("**Fondement juridique**") ==
               "Fondement juridique"

      assert LetterFormatter.to_plain_text("1. **Rappel des faits** : voici les éléments.") ==
               "1. Rappel des faits : voici les éléments."
    end

    test "strippe le gras alternatif `__...__`" do
      assert LetterFormatter.to_plain_text("__Demandes précises__") ==
               "Demandes précises"
    end

    test "strippe le code inline `` `code` ``" do
      assert LetterFormatter.to_plain_text("Voir l'`article 9` de la loi") ==
               "Voir l'article 9 de la loi"
    end

    test "strippe les en-têtes ATX `#`, `##`, … en début de ligne" do
      input = """
      # Objet : Demande de réparation
      ## Section 1
      ### Sous-section
      Le texte courant ne doit PAS être touché : # ceci n'est pas un titre.
      """

      assert LetterFormatter.to_plain_text(input) == """
             Objet : Demande de réparation
             Section 1
             Sous-section
             Le texte courant ne doit PAS être touché : # ceci n'est pas un titre.
             """
    end

    test "ne touche PAS aux astérisques solitaires (faux positifs interdits)" do
      assert LetterFormatter.to_plain_text("Note article L3421*03 du CSP") ==
               "Note article L3421*03 du CSP"

      assert LetterFormatter.to_plain_text("Le syndic _doit_ répondre.") ==
               "Le syndic _doit_ répondre."
    end

    test "ne fusionne pas du gras à travers les sauts de ligne" do
      input = "**Section 1\n\nSection 2** ne doit PAS devenir un seul gras."

      assert LetterFormatter.to_plain_text(input) ==
               "**Section 1\n\nSection 2** ne doit PAS devenir un seul gras."
    end

    test "compresse les enfilades de lignes vides à deux maximum" do
      input = "Bonjour,\n\n\n\n\nVeuillez agréer…"
      assert LetterFormatter.to_plain_text(input) == "Bonjour,\n\nVeuillez agréer…"
    end

    test "gère un texte nil ou vide" do
      assert LetterFormatter.to_plain_text(nil) == ""
      assert LetterFormatter.to_plain_text("") == ""
    end

    test "lettre formelle complète : tout le markdown disparaît, le sens reste" do
      input = """
      Objet : Doléance — trottoirs dégradés

      Madame, Monsieur,

      **1. Rappel des faits**

      Depuis le 12 mars, les trottoirs sont en mauvais état.

      **2. Fondement juridique**

      - Article 9 de la loi du 10 juillet 1965.

      **3. Demandes précises**

      Veuillez intervenir sous deux mois.

      Cordialement,
      Pascale Michon
      """

      output = LetterFormatter.to_plain_text(input)

      refute String.contains?(output, "**")
      assert String.contains?(output, "1. Rappel des faits")
      assert String.contains?(output, "2. Fondement juridique")
      assert String.contains?(output, "3. Demandes précises")
      assert String.contains?(output, "Pascale Michon")
    end
  end
end
