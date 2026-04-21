defmodule KomunBackend.AI.Triage do
  @moduledoc """
  AI triage for newly-created incidents and questions.

  When a resident reports an issue or asks a question, we run a Groq call
  grounded on the règlement de copropriété to produce a first-pass answer.
  The answer is stored on the incident as `ai_answer` and surfaced to the
  author as "proposition non validée" until the syndic / conseil confirms.

  The call runs in a `Task.Supervisor`-managed process so the HTTP request
  returns immediately — if the model is slow or errors out, the incident
  simply lacks an AI answer (the human flow isn't blocked).
  """

  require Logger

  alias KomunBackend.{AI, Documents, Incidents, Repo}
  alias KomunBackend.Incidents.Incident

  @system_prompt """
  Tu es l'assistant d'un syndic. Un résident vient de signaler un incident.
  Ton rôle :

  - Lire l'incident et les documents de la copropriété (entre les balises
    <documents>…</documents>).
  - Proposer une première réponse courte (100 mots max), cordiale, en
    français, qui : (1) reconnaît le problème, (2) donne la piste la plus
    probable de responsabilité (copropriété vs. copropriétaire vs. syndic)
    en citant un article si le règlement le précise, (3) indique la
    prochaine étape concrète (« contactez le syndic X », « demandez un
    devis », etc.).
  - Si l'incident semble urgent (fuite, court-circuit, ascenseur bloqué,
    personne en danger), insiste en une phrase sur l'urgence en tête de
    réponse.
  - Ne fabrique pas d'article ou de règle. Si le règlement ne couvre pas,
    écris « Cet incident n'est pas explicitement couvert par le règlement
    fourni ; le conseil syndical validera la prise en charge. »

  Commence directement par ta réponse, sans phrase d'introduction.
  """

  @doc """
  Kicks off the async triage for an incident. Does NOT block.

  - If `GROQ_API_KEY` is missing we simply no-op (tests + local dev are
    unaffected).
  - If the Task crashes we log and move on; the incident still exists
    without an AI answer.
  """
  def triage_incident_async(%Incident{} = incident) do
    if System.get_env("GROQ_API_KEY") in [nil, ""] do
      :noop
    else
      Task.Supervisor.start_child(
        KomunBackend.TaskSupervisor,
        fn -> triage_incident(incident) end,
        restart: :temporary
      )
    end
  end

  @doc "Synchronously runs the triage — useful for tests."
  def triage_incident(%Incident{id: id, building_id: building_id, title: title,
                                 description: description, category: category,
                                 severity: severity}) do
    # Ground on the règlement only (coproprietaire scope) — enough for most
    # AC / plomberie / bruits questions and keeps the context small.
    context = Documents.context_for_ai(building_id, :coproprietaire)

    user_prompt = """
    <documents>
    #{context}
    </documents>

    Incident signalé :
    - Titre : #{title}
    - Catégorie : #{category}
    - Sévérité : #{severity}
    - Description : #{description}
    """

    messages = [
      %{role: :system, content: @system_prompt},
      %{role: :user, content: user_prompt}
    ]

    case AI.Groq.complete(messages, max_tokens: 600) do
      {:ok, %{content: answer, model: model}} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case Incidents.get_incident(id) do
          nil ->
            Logger.warning("AI triage: incident #{id} disappeared mid-triage")

          incident ->
            incident
            |> Incident.changeset(%{
              ai_answer: answer,
              ai_answered_at: now,
              ai_model: model
            })
            |> Repo.update()
        end

      {:error, reason} ->
        Logger.warning("AI triage for incident #{id} failed: #{inspect(reason)}")
    end
  end
end
