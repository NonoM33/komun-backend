defmodule KomunBackend.AI.IncidentSummarizer do
  @moduledoc """
  Génère un résumé du dossier d'incident via Groq.

  Trois sorties produites :

    * `title` — action-oriented, max 60 caractères. Remplace le titre
      d'origine quand l'incident vient d'un email importé/webhook.
    * `description` — markdown ~3 paragraphes, sections gras, emoji
      🔴🟠🟡🟢 pour signaler la criticité. Affiché sur la fiche détail.
    * `micro_summary` — 1 phrase ultra-courte (≤ 200 chars) pour la
      vue liste/Kanban. Donne le contexte en un coup d'œil.

  Modes :

    * `:all` — regénère titre + description + micro_summary. À utiliser
      après création depuis email/webhook (le contenu d'origine était
      brut).
    * `:micro_only` — ne touche pas au titre ni à la description ;
      génère juste `micro_summary`. À utiliser après création manuelle
      (un copropriétaire a tapé son problème, on respecte ses mots).

  L'appel Groq est asynchrone via Task.Supervisor : pas de blocage HTTP
  côté caller. En cas d'absence de `GROQ_API_KEY` ou d'erreur réseau,
  on log et on no-op — l'incident reste fonctionnel.
  """

  require Logger

  alias KomunBackend.{AI, Incidents, Repo}
  alias KomunBackend.Incidents.{Incident, IncidentComment}

  @system_prompt """
  Tu es l'assistant d'un syndic de copropriété. Tu reçois la
  description d'un incident et l'historique des emails échangés à son
  sujet (avec le syndic LAMY, le promoteur Nexity, la mairie, le
  conseil syndical, des prestataires).

  Produis trois choses :

  1. **title** — titre action-oriented, max 60 caractères, sans emoji,
     sans guillemets. Exemples : « Ascenseur bâtiment B — pannes
     répétées », « Dégâts des eaux Apt 2108 ».

  2. **micro_summary** — UNE phrase ultra-courte, max 180 caractères,
     plain text, sans markdown ni emoji. C'est ce que le résident voit
     dans la vue liste : il doit comprendre l'enjeu en 2 secondes.
     Exemples : « 5 emails échangés avec LAMY et OTIS, intervention
     prévue », « Devis ménage en attente de validation par le conseil ».

  3. **description** — markdown structuré, 3 paragraphes max :
     - Lead : 1 emoji de criticité (🔴 critique, 🟠 important, 🟡 modéré,
       🟢 info) + 1 phrase qui résume le problème.
     - Contexte : 2-3 phrases, où en est le dossier, qui fait quoi.
     - Métadonnées en fin, avec deux espaces avant chaque saut de ligne :
       **Interlocuteurs** : … (séparés par ·)
       **Échanges** : N emails du DD/MM au DD/MM
       **Prochaine étape** : …

  Réponds **strictement** en JSON, format :
  {"title": "...", "micro_summary": "...", "description": "..."}

  Pas de bloc markdown ` ``` `, pas de texte avant ou après le JSON.
  """

  @summarizer_max_tokens 1200

  @doc """
  Lance le résumé en arrière-plan. Ne bloque pas.

    * `mode: :all` (défaut quand l'incident a des emails au moment de
      l'appel) — regen titre + description + micro_summary.
    * `mode: :micro_only` — micro_summary seul.

  Retourne `:noop` quand `GROQ_API_KEY` est absent, sinon `:ok`.
  """
  @spec summarize_async(Incident.t(), keyword()) :: :ok | :noop
  def summarize_async(%Incident{} = incident, opts \\ []) do
    if System.get_env("GROQ_API_KEY") in [nil, ""] do
      :noop
    else
      Task.Supervisor.start_child(
        KomunBackend.TaskSupervisor,
        fn -> summarize(incident, opts) end,
        restart: :temporary
      )

      :ok
    end
  end

  @doc "Synchrone — utile pour les tests + l'endpoint de regen manuelle."
  @spec summarize(Incident.t(), keyword()) :: {:ok, Incident.t()} | {:error, term()}
  def summarize(%Incident{} = incident, opts \\ []) do
    mode = Keyword.get(opts, :mode, :all)
    incident = Repo.preload(incident, comments: :author)

    case run_groq(incident) do
      {:ok, %{"title" => title, "micro_summary" => micro, "description" => desc}, model} ->
        attrs = build_attrs(mode, title, micro, desc, model)

        case incident |> Incident.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            {:ok, updated}

          {:error, cs} ->
            Logger.warning(
              "AI summarizer save failed for incident #{incident.id}: #{inspect(cs.errors)}"
            )

            {:error, cs}
        end

      {:ok, partial, _model} ->
        Logger.warning(
          "AI summarizer returned an unexpected JSON shape for incident #{incident.id}: #{inspect(partial)}"
        )

        {:error, :bad_payload}

      {:error, reason} = err ->
        Logger.warning(
          "AI summarizer failed for incident #{incident.id}: #{inspect(reason)}"
        )

        err
    end
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp build_attrs(:micro_only, _title, micro, _desc, _model) do
    %{micro_summary: truncate(micro, 200)}
  end

  defp build_attrs(:all, title, micro, desc, model) do
    %{
      title: truncate(title, 200),
      description: desc,
      micro_summary: truncate(micro, 200),
      ai_model: model
    }
  end

  defp truncate(nil, _), do: nil

  defp truncate(s, max) when is_binary(s) do
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end

  defp run_groq(incident) do
    user_prompt = build_user_prompt(incident)

    messages = [
      %{role: :system, content: @system_prompt},
      %{role: :user, content: user_prompt}
    ]

    case AI.Groq.complete(messages,
           max_tokens: @summarizer_max_tokens,
           temperature: 0.2
         ) do
      {:ok, %{content: content, model: model}} ->
        case parse_json(content) do
          {:ok, json} -> {:ok, json, model}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp build_user_prompt(incident) do
    """
    Incident :
    - Titre actuel : #{incident.title}
    - Catégorie : #{incident.category}
    - Sévérité : #{incident.severity}
    - Statut : #{incident.status}
    - Description actuelle :
    #{incident.description}

    Historique des échanges (chronologique, le 1er en premier) :
    #{format_comments(incident.comments)}
    """
  end

  defp format_comments(comments) when is_list(comments) and comments != [] do
    comments
    |> Enum.sort_by(& &1.inserted_at, NaiveDateTime)
    |> Enum.map(&format_comment/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp format_comments(_), do: "(aucun échange à date)"

  defp format_comment(%IncidentComment{body: body, author: author, inserted_at: at}) do
    name =
      cond do
        is_struct(author) and not is_nil(author.first_name) ->
          "#{author.first_name} #{author.last_name || ""}" |> String.trim()

        is_struct(author) and not is_nil(author.email) ->
          author.email

        true ->
          "?"
      end

    # On garde le body tel quel : si c'est un email importé (préfixe 📧)
    # le LLM verra les headers De/À/Date et pourra extraire la chronologie.
    "[#{at}] #{name} :\n#{body}"
  end

  # Groq renvoie parfois le JSON enrobé d'un bloc markdown ```json…```
  # malgré l'instruction. On l'enlève avant parsing.
  defp parse_json(content) do
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{} = json} -> {:ok, json}
      {:ok, _other} -> {:error, :not_an_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  # ── Helpers exposés ──────────────────────────────────────────────────────

  @doc """
  Heuristique : un incident "alimenté par emails" est un incident dont
  au moins un commentaire commence par 📧 (préfixe utilisé par
  l'importeur Gmail et le webhook). Utile pour décider quel mode de
  résumé lancer après création.
  """
  def email_driven?(%Incident{} = incident) do
    incident = Repo.preload(incident, :comments)

    Enum.any?(incident.comments || [], fn c ->
      is_binary(c.body) and String.starts_with?(c.body, "📧")
    end)
  end

  @doc "Force-trigger un résumé sur un incident donné (sync). Utilisé par l'API."
  def regenerate(incident_id, opts \\ []) do
    case Incidents.get_incident(incident_id) do
      nil -> {:error, :not_found}
      incident -> summarize(incident, opts)
    end
  end
end
