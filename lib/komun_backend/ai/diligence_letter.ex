defmodule KomunBackend.AI.DiligenceLetter do
  @moduledoc """
  Génération de courriers formels pour une diligence (procédure trouble
  anormal du voisinage). Deux registres :

  - `:saisine` — courrier rédigé par le **président du conseil syndical**
    et adressé au **syndic** pour saisine officielle (LRAR), demandant
    l'envoi d'une mise en demeure au copropriétaire concerné.

  - `:mise_en_demeure` — courrier rédigé par le **syndic** et adressé au
    **copropriétaire** (et le cas échéant au locataire via le bailleur),
    rappelant le règlement de copropriété et les obligations légales,
    avec sommation de cesser le trouble.

  Les deux sont en plain text — le frontend les affiche dans une modale
  et propose un bouton « Copier » / « Télécharger .txt » pour que le
  destinataire les insère dans Word avant impression / envoi LRAR.

  ## Pourquoi un fallback statique

  Si `GROQ_API_KEY` est absente (dev local sans clé, panne réseau Groq,
  rate-limit, …), on retourne quand même un **template figé** plutôt
  qu'une erreur. La logique métier est : un président de CS ne doit
  jamais se retrouver bloqué parce que l'IA a hoqueté ; il préfère un
  modèle générique à compléter manuellement plutôt que rien.
  """

  require Logger

  alias KomunBackend.{AI, Diligences}
  alias KomunBackend.AI.LetterFormatter
  alias KomunBackend.Diligences.Diligence

  @kinds [:saisine, :mise_en_demeure]

  @system_saisine """
  Tu es président du conseil syndical d'une copropriété française. Tu
  rédiges un courrier formel adressé au syndic pour saisir
  officiellement la copropriété d'un trouble anormal du voisinage. Tu
  produis directement le texte du courrier, sans phrase d'introduction.

  ⚠️ TEXTE BRUT — aucun markdown : pas de **gras**, pas de *italique*,
  pas de `# titre`, pas de blocs ``` `code` ```. Le courrier est envoyé
  par email ou LRAR via l'API La Poste — chaque caractère markdown
  apparaît littéralement chez le destinataire. Pour mettre en avant un
  titre de section, utilise des MAJUSCULES ou de la casse normale, pas
  d'astérisques. Pour les listes, numérote « 1. », « 2. » ou utilise
  un tiret cadratin « — ».

  Format strict :
  - En-tête « Objet : » clair (« Saisine officielle — trouble anormal du
    voisinage »).
  - Exposé des faits : nature du trouble, fréquence, lieux concernés
    (appartement / parties communes / VMC), nombre de résidents gênés.
  - Rappel du fondement juridique : article 9 de la loi du 10 juillet
    1965, clause de tranquillité du règlement de copropriété, et si
    pertinent infraction pénale (article L3421-1 du Code de la santé
    publique pour les stupéfiants).
  - Demande explicite : que le syndic envoie une mise en demeure LRAR
    au copropriétaire concerné, sous astreinte. Si l'occupant est
    locataire, demande que la mise en demeure soit également relayée
    au bailleur pour activation éventuelle de la clause résolutoire.
  - Liste des pièces jointes au courrier (journal des nuisances,
    attestations sur l'honneur CERFA n°11527*03 des résidents gênés,
    constat de commissaire de justice si disponible).
  - Ton ferme mais courtois, volonté de règlement amiable rappelée,
    avant escalade conciliateur de justice / tribunal judiciaire.

  Termine par la formule de politesse (« Je vous prie d'agréer… ») et
  une signature « Le Président du conseil syndical ».
  """

  @system_mise_en_demeure """
  Tu es le syndic professionnel d'une copropriété française. Tu rédiges
  une mise en demeure formelle (LRAR) adressée au copropriétaire à
  l'origine d'un trouble anormal du voisinage, suite à la saisine du
  conseil syndical. Tu produis directement le texte du courrier, sans
  phrase d'introduction.

  ⚠️ TEXTE BRUT — aucun markdown : pas de **gras**, pas de *italique*,
  pas de `# titre`, pas de blocs ``` `code` ```. Le courrier est envoyé
  par LRAR (impression papier) ou par email — chaque caractère markdown
  apparaît littéralement et fait amateur. Pour les sections, utilise
  des MAJUSCULES ou de la casse normale ; pour les listes, numérote
  « 1. », « 2. » ou utilise un tiret cadratin « — ».

  Format strict :
  - En-tête « Objet : » clair (« Mise en demeure — cessation immédiate
    du trouble »).
  - Exposé des faits déjà signalés (sans révéler l'identité des
    plaignants).
  - Rappel des obligations contractuelles : règlement de copropriété
    (clause de tranquillité, jouissance paisible), article 9 de la loi
    du 10 juillet 1965.
  - Si le trouble implique des stupéfiants, mention de l'article
    L3421-1 du Code de la santé publique (infraction pénale).
  - Sommation : cessation immédiate du trouble. Délai de 15 jours pour
    confirmation écrite. À défaut, action en justice au nom du syndicat
    des copropriétaires (article 1240 du Code civil), demande de
    cessation sous astreinte et dommages-intérêts.
  - Si l'occupant est un locataire : rappel que le bailleur est
    responsable des nuisances de son occupant (article 1729 du Code
    civil) et invitation à activer la clause résolutoire du bail.

  Termine par la formule de politesse et la signature « Le Syndic ».
  """

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Génère un courrier puis le persiste sur la diligence. Retourne la
  diligence rechargée avec le champ `saisine_syndic_letter` ou
  `mise_en_demeure_letter` peuplé.

  Si `GROQ_API_KEY` est absente OU si l'appel Groq échoue, on retombe
  sur un template statique (voir `static_template/2`) — aucun cas
  d'échec n'est remonté à l'appelant en dehors d'une erreur DB.
  """
  def generate_letter(%Diligence{} = diligence, kind) when kind in @kinds do
    text =
      case do_generate(diligence, kind) do
        {:ok, ai_text} ->
          ai_text

        {:error, reason} ->
          Logger.warning(
            "[diligences] AI letter (#{kind}) for diligence #{diligence.id} fell back to static template: #{inspect(reason)}"
          )

          static_template(diligence, kind)
      end

    Diligences.set_letter(diligence, kind, text)
  end

  def generate_letter(_, kind),
    do: {:error, {:invalid_kind, kind, "must be one of #{inspect(@kinds)}"}}

  @doc """
  Variante sans persistance — utile pour preview côté front avant
  d'écrire en base. Retourne directement le texte (IA ou fallback).
  """
  def preview(%Diligence{} = diligence, kind) when kind in @kinds do
    case do_generate(diligence, kind) do
      {:ok, ai_text} -> {:ok, ai_text, :ai}
      {:error, _reason} -> {:ok, static_template(diligence, kind), :static}
    end
  end

  @doc false
  def kinds, do: @kinds

  # ── Internals ─────────────────────────────────────────────────────────────

  defp do_generate(diligence, kind) do
    if System.get_env("GROQ_API_KEY") in [nil, ""] do
      {:error, :no_ai_key}
    else
      messages = [
        %{role: :system, content: system_prompt(kind)},
        %{role: :user, content: user_prompt(diligence)}
      ]

      complete_with_retry(messages, 4000)
    end
  end

  # Une lettre formelle ne doit jamais être livrée tronquée. Si Groq
  # signale `finish_reason: "length"`, on retente une fois avec un
  # budget plus large ; sinon on tombe sur le template statique
  # plutôt que de persister un courrier qui s'arrête au milieu d'une
  # phrase.
  defp complete_with_retry(messages, max_tokens) do
    case AI.Groq.complete(messages, max_tokens: max_tokens, temperature: 0.3) do
      {:ok, %{finish_reason: "length"}} when max_tokens < 8000 ->
        Logger.warning(
          "[diligences] AI letter truncated at #{max_tokens} tokens, retrying with 8000."
        )

        complete_with_retry(messages, 8000)

      {:ok, %{finish_reason: "length"}} ->
        {:error, :truncated}

      {:ok, %{content: content}} when is_binary(content) and byte_size(content) > 0 ->
        {:ok, LetterFormatter.to_plain_text(content)}

      {:ok, _} ->
        {:error, :empty_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp system_prompt(:saisine), do: @system_saisine
  defp system_prompt(:mise_en_demeure), do: @system_mise_en_demeure

  defp user_prompt(%Diligence{} = d) do
    """
    Diligence à traiter :
    - Titre : #{d.title}
    - Description : #{d.description || "(non précisée)"}
    - Source du trouble : #{format_source(d)}
    - Notes des étapes 2 (collecte preuves) et 3 (identification source) :
    #{format_steps_notes(d)}
    - Pièces déjà collectées : #{format_files(d)}
    """
  end

  defp format_source(%Diligence{source_type: nil}),
    do: "non précisée — adapter le courrier au cas général"

  defp format_source(%Diligence{source_type: :copro_owner, source_label: label}),
    do: "Copropriétaire occupant#{maybe_label(label)}"

  defp format_source(%Diligence{source_type: :tenant, source_label: label}),
    do: "Locataire (le copropriétaire bailleur est responsable)#{maybe_label(label)}"

  defp format_source(%Diligence{source_type: :unknown, source_label: label}),
    do: "Non identifié à ce stade#{maybe_label(label)}"

  defp maybe_label(nil), do: ""
  defp maybe_label(""), do: ""
  defp maybe_label(label), do: " — #{label}"

  defp format_steps_notes(%Diligence{steps: %Ecto.Association.NotLoaded{}}), do: "(non chargés)"
  defp format_steps_notes(%Diligence{steps: nil}), do: "(aucune)"

  defp format_steps_notes(%Diligence{steps: steps}) do
    relevant = Enum.filter(steps, &(&1.step_number in [2, 3] and is_binary(&1.notes)))

    case relevant do
      [] ->
        "(aucune note rédigée)"

      list ->
        Enum.map_join(list, "\n", fn s ->
          "      Étape #{s.step_number} : #{s.notes}"
        end)
    end
  end

  defp format_files(%Diligence{files: %Ecto.Association.NotLoaded{}}), do: "(non chargées)"
  defp format_files(%Diligence{files: nil}), do: "(aucune)"
  defp format_files(%Diligence{files: []}), do: "(aucune)"

  defp format_files(%Diligence{files: files}) do
    files
    |> Enum.group_by(& &1.kind)
    |> Enum.map_join(", ", fn {kind, fs} -> "#{length(fs)} #{kind}" end)
  end

  # ── Templates statiques (fallback) ───────────────────────────────────────

  @doc """
  Template figé utilisé quand l'IA n'est pas disponible. Volontairement
  générique mais déjà cliquable — le président de CS peut copier, coller
  dans Word, compléter les `[…]` et envoyer.
  """
  def static_template(%Diligence{} = d, :saisine) do
    """
    Objet : Saisine officielle — trouble anormal du voisinage

    Madame, Monsieur,

    En qualité de président du conseil syndical de la résidence, je
    vous saisis officiellement, au nom des résidents concernés, d'un
    trouble anormal du voisinage qui perdure malgré les démarches
    amiables déjà entreprises.

    Faits constatés :
    #{d.title}
    #{d.description || "[Description détaillée à compléter]"}

    Source identifiée : #{format_source(d)}

    Les troubles décrits ci-dessus contreviennent :
      - aux articles relatifs à la jouissance paisible du règlement de
        copropriété ;
      - à l'article 9 de la loi du 10 juillet 1965 fixant le statut de
        la copropriété des immeubles bâtis ;
      - le cas échéant à l'article L3421-1 du Code de la santé publique
        (infraction pénale en cas d'usage de stupéfiants).

    En conséquence, je vous prie de bien vouloir, dans les meilleurs
    délais :
      1. Adresser au copropriétaire concerné une mise en demeure par
         lettre recommandée avec accusé de réception, lui sommant de
         faire cesser immédiatement le trouble ;
      2. Si l'occupant est un locataire, transmettre cette mise en
         demeure au bailleur afin qu'il prenne ses responsabilités
         (article 1729 du Code civil et clause résolutoire du bail) ;
      3. Tenir le conseil syndical informé des suites données.

    Pièces jointes :
      - Journal daté des nuisances ;
      - Attestations sur l'honneur (CERFA n°11527*03) des résidents
        gênés ;
      - Constat de commissaire de justice (si applicable).

    Dans l'attente de votre intervention, et soucieux d'un règlement
    amiable avant toute saisine du conciliateur de justice ou du
    tribunal judiciaire, je vous prie d'agréer, Madame, Monsieur,
    l'expression de mes salutations distinguées.

    Le Président du conseil syndical
    """
  end

  def static_template(%Diligence{} = d, :mise_en_demeure) do
    """
    Objet : Mise en demeure — cessation immédiate du trouble

    Madame, Monsieur,

    Le syndicat des copropriétaires, alerté par le conseil syndical, a
    été saisi des troubles suivants vous concernant :

    #{d.title}
    #{d.description || "[Description détaillée à compléter]"}

    Ces faits sont contraires :
      - aux clauses de tranquillité et de jouissance paisible du
        règlement de copropriété ;
      - à l'article 9 de la loi du 10 juillet 1965 ;
      - le cas échéant, à l'article L3421-1 du Code de la santé
        publique relatif à la consommation de stupéfiants.

    En conséquence, je vous mets en demeure, par la présente lettre
    recommandée avec accusé de réception, de **faire cesser
    immédiatement** ces troubles, et de m'en confirmer la cessation par
    écrit dans un délai de **quinze (15) jours** à compter de la
    réception de la présente.

    À défaut, le syndicat des copropriétaires se verra contraint
    d'engager toute action en justice utile au visa de l'article 1240
    du Code civil et du règlement de copropriété, avec demande de
    cessation sous astreinte et de dommages et intérêts.

    Si vous donnez votre logement en location, je vous rappelle que
    vous demeurez responsable des agissements de votre locataire
    (article 1729 du Code civil) et qu'il vous appartient, le cas
    échéant, d'activer la clause résolutoire de votre bail.

    Je vous prie d'agréer, Madame, Monsieur, l'expression de mes
    salutations distinguées.

    Le Syndic
    """
  end
end
