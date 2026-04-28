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

  # Budget initial pour une lettre formelle française (faits, fondement
  # juridique, demandes précises, signature). Une lettre type rentre
  # confortablement dans 4000 tokens.
  @letter_max_tokens 4000

  # Budget de retry si la première génération est tronquée. On double
  # plutôt que d'extrapoler la longueur réelle — gpt-oss-120b accepte
  # jusqu'à 32k tokens en sortie, donc 8000 reste très large.
  @letter_retry_max_tokens 8000

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

  Règles strictes sur l'identité — n'invente RIEN :

  - Pour la signature, utilise littéralement le bloc <signataire> fourni
    (nom, prénom, mention sous la signature). Si une "mention" est
    donnée, c'est elle qui apparaît sous le nom — pas un titre que tu
    devines toi-même. Si la mention est absente, signe simplement avec
    nom + prénom, sans inventer de fonction. Si la mention contredit
    manifestement le rôle vérifié (`role_verifie`), conserve la mention
    fournie sans la corriger silencieusement.
  - Pour le destinataire, utilise littéralement le bloc <destinataire>
    fourni (nom, adresse postale). Ne devine pas un nom de cabinet ni
    une adresse à partir du contexte — si un champ est manquant, omets
    cette ligne plutôt que de la fabriquer.

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

  def generate_letter(%Doleance{} = doleance, actor_id \\ nil, opts \\ []) do
    if System.get_env("GROQ_API_KEY") in [nil, ""] do
      {:error, :no_ai_key}
    else
      do_generate_letter(doleance, actor_id, opts)
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

  defp do_generate_letter(doleance, actor_id, opts) do
    context = Documents.context_for_ai(doleance.building_id, :coproprietaire)
    support_count = length(doleance.supports || [])
    signer = Keyword.get(opts, :signer, %{})

    user_prompt = """
    <documents>
    #{context}
    </documents>

    <signataire>
    #{format_signer(signer)}
    </signataire>

    <destinataire>
    #{format_recipient(doleance)}
    </destinataire>

    Doléance à traiter :
    - Titre : #{doleance.title}
    - Catégorie : #{doleance.category}
    - Sévérité : #{doleance.severity}
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

    case complete_letter(messages, @letter_max_tokens) do
      {:ok, %{content: letter, model: model}} ->
        case Doleances.save_ai_letter(doleance, letter, model, actor_id) do
          {:ok, updated} -> {:ok, updated}
          error -> error
        end

      {:error, :truncated} ->
        Logger.error(
          "AI letter for doleance #{doleance.id} was truncated even at #{@letter_retry_max_tokens} tokens — refusing to persist a partial letter."
        )

        {:error, :truncated}

      {:error, reason} = err ->
        Logger.warning("AI letter for doleance #{doleance.id} failed: #{inspect(reason)}")

        err
    end
  end

  # Appelle Groq et, si la réponse est tronquée par la limite de
  # tokens, retente une fois avec un budget plus large. Une lettre
  # formelle ne doit JAMAIS être persistée à moitié — l'utilisateur
  # se retrouverait avec un courrier qui s'arrête au milieu d'une
  # phrase ("...à compter de la").
  defp complete_letter(messages, max_tokens) do
    case AI.Groq.complete(messages, max_tokens: max_tokens) do
      {:ok, %{finish_reason: "length"}} when max_tokens < @letter_retry_max_tokens ->
        Logger.warning(
          "AI letter truncated at #{max_tokens} tokens, retrying with #{@letter_retry_max_tokens}."
        )

        complete_letter(messages, @letter_retry_max_tokens)

      {:ok, %{finish_reason: "length"}} ->
        {:error, :truncated}

      {:ok, _} = ok ->
        ok

      {:error, _} = err ->
        err
    end
  end

  defp format_signer(signer) when is_map(signer) do
    first = Map.get(signer, :first_name) || ""
    last = Map.get(signer, :last_name) || ""
    label = Map.get(signer, :role_label)
    verified = Map.get(signer, :verified_role)
    email = Map.get(signer, :email)

    name = String.trim("#{first} #{last}")
    name = if name == "", do: "(non précisé)", else: name

    """
    - Prénom & nom : #{name}
    - Mention à reprendre sous la signature : #{label || "(aucune — signer simplement avec le nom, ne pas inventer de titre)"}
    - role_verifie (côté plateforme, à titre indicatif) : #{verified || "(aucun — l'utilisateur n'a pas de rôle officiel dans ce bâtiment)"}
    - Email de contact : #{email || "(non communiqué)"}
    """
    |> String.trim()
  end

  defp format_signer(_),
    do:
      "(aucune information sur le signataire — signer 'Le conseil syndical' sans inventer de nom)"

  defp format_recipient(doleance) do
    kind_label =
      case doleance.target_kind do
        :syndic -> "Syndic"
        :constructor -> "Constructeur"
        :insurance -> "Assurance"
        :authority -> "Autorité / service public"
        :other -> "Autre"
        nil -> "Destinataire (par défaut : syndic)"
        _ -> "Destinataire"
      end

    """
    - Type : #{kind_label}
    - Nom : #{presence_or(doleance.target_name, "(non communiqué — omettre la ligne nom dans l'en-tête)")}
    - Email : #{presence_or(doleance.target_email, "(non communiqué — ne pas en inventer)")}
    - Adresse postale : #{presence_or(doleance.target_address, "(non communiquée — omettre la ligne adresse dans l'en-tête, mentionner que le courrier sera remis en main propre ou par email)")}
    """
    |> String.trim()
  end

  defp presence_or(nil, fallback), do: fallback
  defp presence_or("", fallback), do: fallback
  defp presence_or(value, _fallback), do: value

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
