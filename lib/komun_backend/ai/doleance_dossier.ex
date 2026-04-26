defmodule KomunBackend.AI.DoleanceDossier do
  @moduledoc """
  AI helpers for building a complete grievance dossier :

    * `generate_letter/1` — writes a formal French letter to the syndic,
      builder, or other authority, grounded on the règlement de
      copropriété when useful.
    * `suggest_experts/1` — lists the kinds of experts that would
      strengthen the case (huissier, bureau d'études, avocat, expert
      judiciaire, assurance, …) with a short reason for each.

  Both helpers run synchronously on demand (triggered from a button in
  the UI, so the wait is expected and the user sees the result
  immediately rather than polling).
  """

  require Logger

  alias KomunBackend.{AI, Documents, Doleances}
  alias KomunBackend.Doleances.Doleance

  @letter_prompt """
  Tu es juriste en copropriété. Un copropriétaire (ou un groupe) vient
  de te soumettre une doléance persistante qui justifie une saisine
  formelle. Ton rôle :

  - Rédiger un courrier formel en français, daté, structuré, prêt à
    être envoyé au destinataire indiqué (syndic, constructeur,
    assurance, autorité, …).
  - Objet clair, exposé des faits (dates, lieux, nombre de
    copropriétaires concernés), demande précise, rappel du délai légal
    de réponse si pertinent.
  - Si le règlement de copropriété (entre <documents>…</documents>)
    couvre le sujet, cite le ou les articles utiles. Sinon, ne fabrique
    pas d'article.
  - Ton ferme mais courtois. Pas de menace gratuite. Rappelle la
    volonté d'un règlement amiable avant toute action judiciaire.
  - Termine par les pièces jointes (photos, devis, rapports d'expert,
    témoignages) en listant ce qui est attaché à la doléance.

  Commence directement par la lettre, sans phrase d'introduction, sans
  bloc markdown.
  """

  @experts_prompt """
  Tu es un expert en gestion de copropriété. À partir d'une doléance,
  propose la liste des interlocuteurs professionnels à solliciter pour
  renforcer le dossier.

  Format strictement :

  - Une liste à puces, 3 à 5 items maximum.
  - Chaque puce : **Nom du métier** — en une ou deux phrases : pourquoi
    ce professionnel est pertinent pour ce cas précis, ce qu'il apporte
    (rapport, constat, expertise), et à quel moment le saisir.
  - Ordre : du plus immédiat / peu coûteux au plus engageant (ex.
    commence par le syndic ou un constat d'huissier avant d'envisager
    un avocat).
  - Pas d'introduction, pas de conclusion, pas de disclaimer générique.
  """

  # ── Public API ───────────────────────────────────────────────────────────

  def generate_letter(%Doleance{} = doleance, actor_id \\ nil) do
    if System.get_env("GROQ_API_KEY") in [nil, ""] do
      {:error, :no_ai_key}
    else
      do_generate_letter(doleance, actor_id)
    end
  end

  def suggest_experts(%Doleance{} = doleance, actor_id \\ nil) do
    if System.get_env("GROQ_API_KEY") in [nil, ""] do
      {:error, :no_ai_key}
    else
      do_suggest_experts(doleance, actor_id)
    end
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp do_generate_letter(doleance, actor_id) do
    context = Documents.context_for_ai(doleance.building_id, :coproprietaire)
    support_count = length(doleance.supports || [])

    user_prompt = """
    <documents>
    #{context}
    </documents>

    Doléance à traiter :
    - Titre : #{doleance.title}
    - Catégorie : #{doleance.category}
    - Sévérité : #{doleance.severity}
    - Destinataire visé : #{format_target(doleance)}
    - Nombre de copropriétaires co-signataires : #{support_count}
    - Description : #{doleance.description}

    Témoignages des co-signataires :
    #{format_supports(doleance.supports)}

    Pièces jointes disponibles :
    #{format_attachments(doleance)}
    """

    messages = [
      %{role: :system, content: @letter_prompt},
      %{role: :user, content: user_prompt}
    ]

    case AI.Groq.complete(messages, max_tokens: 1400) do
      {:ok, %{content: letter, model: model}} ->
        case Doleances.save_ai_letter(doleance, letter, model, actor_id) do
          {:ok, updated} -> {:ok, updated}
          error -> error
        end

      {:error, reason} = err ->
        Logger.warning(
          "AI letter for doleance #{doleance.id} failed: #{inspect(reason)}"
        )

        err
    end
  end

  defp do_suggest_experts(doleance, actor_id) do
    user_prompt = """
    Doléance :
    - Titre : #{doleance.title}
    - Catégorie : #{doleance.category}
    - Sévérité : #{doleance.severity}
    - Destinataire visé : #{format_target(doleance)}
    - Description : #{doleance.description}
    """

    messages = [
      %{role: :system, content: @experts_prompt},
      %{role: :user, content: user_prompt}
    ]

    case AI.Groq.complete(messages, max_tokens: 500) do
      {:ok, %{content: suggestions, model: model}} ->
        case Doleances.save_ai_suggestions(doleance, suggestions, model, actor_id) do
          {:ok, updated} -> {:ok, updated}
          error -> error
        end

      {:error, reason} = err ->
        Logger.warning(
          "AI expert suggestions for doleance #{doleance.id} failed: #{inspect(reason)}"
        )

        err
    end
  end

  defp format_target(%Doleance{target_kind: nil, target_name: nil}),
    do: "non précisé — rédige un courrier adressé au syndic"

  defp format_target(%Doleance{target_kind: kind, target_name: name}) do
    kind_label =
      case kind do
        :syndic -> "Syndic"
        :constructor -> "Constructeur"
        :insurance -> "Assurance"
        :authority -> "Autorité / service public"
        :other -> "Autre"
        _ -> "Destinataire"
      end

    case name do
      nil -> kind_label
      "" -> kind_label
      n -> "#{kind_label} — #{n}"
    end
  end

  defp format_supports(nil), do: "(aucun)"

  defp format_supports(%Ecto.Association.NotLoaded{}), do: "(non chargés)"

  defp format_supports([]), do: "(aucun co-signataire pour le moment)"

  defp format_supports(supports) do
    supports
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {s, i} ->
      name =
        cond do
          is_nil(s.user) -> "Co-signataire"
          is_binary(s.user.first_name) -> s.user.first_name
          true -> s.user.email
        end

      comment = s.comment || "(pas de commentaire)"
      "  #{i}. #{name} : #{comment}"
    end)
  end

  defp format_attachments(%Doleance{photo_urls: photos, document_urls: docs}) do
    photo_count = length(photos || [])
    doc_count = length(docs || [])

    cond do
      photo_count + doc_count == 0 -> "(aucune pièce jointe)"
      true -> "#{photo_count} photo(s), #{doc_count} document(s)"
    end
  end
end
