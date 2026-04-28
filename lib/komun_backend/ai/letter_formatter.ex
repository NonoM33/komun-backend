defmodule KomunBackend.AI.LetterFormatter do
  @moduledoc """
  Nettoie un courrier IA avant persistance.

  Les lettres formelles (doléance, saisine syndic, mise en demeure) sont
  affichées dans un `<pre>` côté frontend, copiées tel quel par
  l'utilisateur, et destinées à être envoyées par email ou via l'API
  La Poste. **Aucun markdown ne doit subsister** : un `**Fondement
  juridique**` recopié dans un email apparaît littéralement chez le
  destinataire et fait amateur.

  On strippe uniquement les marqueurs **sans ambiguïté** (paires `**`,
  paires `__`, blocs ``` `code` ```, et `#` en début de ligne). On
  laisse les `*` et `_` solitaires intacts — ils sont parfois utilisés
  dans le texte courant et le risque de faux positif est trop grand.

  Le prompt système interdit explicitement le markdown ; cette fonction
  est une **ceinture en plus des bretelles** : si l'IA dérape (et elle
  dérape parfois sur des sections numérotées), le courrier sauvegardé
  reste propre.
  """

  @spec to_plain_text(String.t() | nil) :: String.t()
  def to_plain_text(nil), do: ""

  def to_plain_text(text) when is_binary(text) do
    text
    |> strip_paired("**")
    |> strip_paired("__")
    |> strip_inline_code()
    |> strip_atx_headings()
    |> normalize_blank_lines()
  end

  # `**bold**` → `bold`. Greedy non-cross-line match.
  defp strip_paired(text, "**") do
    Regex.replace(~r/\*\*([^*\n]+?)\*\*/, text, "\\1")
  end

  defp strip_paired(text, "__") do
    Regex.replace(~r/__([^_\n]+?)__/, text, "\\1")
  end

  # `` `code` `` → `code`
  defp strip_inline_code(text) do
    Regex.replace(~r/`([^`\n]+?)`/, text, "\\1")
  end

  # `# Heading`, `## Heading`, … (en début de ligne) → `Heading`.
  defp strip_atx_headings(text) do
    Regex.replace(~r/^#+\s+/m, text, "")
  end

  # Limite les enfilades de lignes vides à deux maximum (pour éviter
  # qu'un courrier finisse avec 5 lignes blanches après le strip).
  defp normalize_blank_lines(text) do
    Regex.replace(~r/\n{3,}/, text, "\n\n")
  end
end
