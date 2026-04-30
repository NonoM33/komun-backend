defmodule KomunBackend.Incidents.Incident do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "incidents" do
    field :title, :string
    field :description, :string
    field :category, Ecto.Enum,
      values: [:plomberie, :electricite, :ascenseur, :serrurerie, :toiture,
               :facades, :parties_communes, :espaces_verts, :autre]
    field :severity, Ecto.Enum, values: [:critical, :high, :medium, :low], default: :medium
    field :status, Ecto.Enum,
      values: [:brouillon, :open, :in_progress, :resolved, :closed, :rejected], default: :open
    field :photo_urls, {:array, :string}, default: []

    # Résumé ultra-court (~ 1 phrase, ≤ 200 chars) généré par l'IA après
    # création / mise à jour. Utilisé par `IncidentRouter.format_incident/1`
    # pour donner au LLM un contexte compact des dossiers ouverts. Nil tant
    # que `IncidentSummarizer` n'a pas tourné — fallback sur la description.
    field :micro_summary, :string

    field :resolved_at, :utc_datetime
    field :resolution_note, :string
    field :location, :string
    field :lot_number, :string

    # Niveau de confidentialité :
    # - :standard     → visible à tous les membres du bâtiment
    # - :council_only → réservé au syndic / conseil syndical / super_admin.
    #                   L'identité du signaleur n'est jamais divulguée dans
    #                   le payload sérialisé, l'IA n'est pas déclenchée
    #                   (contenu sensible) et les notifs push ne partent
    #                   qu'aux rôles privilégiés.
    field :visibility, Ecto.Enum, values: [:standard, :council_only], default: :standard

    # Sous-type optionnel — détermine si une notification ciblée est envoyée
    # aux voisins concernés (logement en dessous pour :water_leak, voisins
    # de palier pour :noise). nil = pas de routage spécifique.
    field :subtype, Ecto.Enum, values: [:water_leak, :noise, :other]

    # AI triage — populated asynchronously after creation. Residents see it
    # as "réponse proposée par l'assistant" until the syndic / conseil
    # confirms it (ai_answer_confirmed_at set).
    field :ai_answer, :string
    field :ai_answered_at, :utc_datetime
    field :ai_model, :string
    field :ai_answer_confirmed_at, :utc_datetime

    # Métadonnées de l'agent AI qui a ingéré ce dossier depuis un email
    # (routine d'ingestion). Utilisé pour comparer les modèles et suivre
    # le coût. Forme : `{model, provider, input_tokens, output_tokens,
    # cost_usd, response_ms, decided_at}`. Voir migration
    # AddIngestionMetadataToCases. Nil si le dossier a été créé à la main.
    field :ai_ingestion_metadata, :map

    # Un incident vit soit sur un bâtiment précis, soit sur la résidence
    # entière (auquel cas tous les bâtiments le voient). Exactement un des
    # deux doit être set — verrou côté DB via le check_constraint
    # `case_scope_xor` (cf. migration AddResidenceScopeToCases).
    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :residence, KomunBackend.Residences.Residence
    belongs_to :reporter, KomunBackend.Accounts.User, foreign_key: :reporter_id
    belongs_to :assignee, KomunBackend.Accounts.User, foreign_key: :assignee_id
    belongs_to :ai_answer_confirmed_by, KomunBackend.Accounts.User,
      foreign_key: :ai_answer_confirmed_by_id
    has_many :comments, KomunBackend.Incidents.IncidentComment
    has_many :files, KomunBackend.Incidents.IncidentFile

    timestamps(type: :utc_datetime)
  end

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [:title, :description, :category, :severity, :status,
                    :photo_urls, :location, :lot_number, :building_id, :residence_id,
                    :reporter_id, :assignee_id, :resolution_note, :visibility, :subtype,
                    :ai_answer, :ai_answered_at, :ai_model,
                    :ai_answer_confirmed_at, :ai_answer_confirmed_by_id,
                    :micro_summary, :ai_ingestion_metadata])
    |> validate_required([:title, :description, :category, :reporter_id])
    |> validate_length(:title, min: 5, max: 200)
    |> validate_scope_xor()
    |> check_constraint(:building_id, name: :case_scope_xor,
                        message: "doit être lié à un bâtiment OU à une résidence, pas aux deux")
  end

  # Exactement un de building_id / residence_id doit être set. Vérifié
  # ici en amont pour produire une erreur claire avant que la DB nous
  # claque le check_constraint.
  defp validate_scope_xor(changeset) do
    building = get_field(changeset, :building_id)
    residence = get_field(changeset, :residence_id)

    cond do
      building && residence ->
        add_error(changeset, :residence_id,
          "ne peut pas être défini si building_id est aussi défini")

      is_nil(building) && is_nil(residence) ->
        add_error(changeset, :building_id,
          "building_id ou residence_id est requis")

      true ->
        changeset
    end
  end

  def resolve_changeset(incident, note) do
    incident
    |> cast(%{status: :resolved, resolution_note: note,
              resolved_at: DateTime.utc_now() |> DateTime.truncate(:second)}, [:status, :resolution_note, :resolved_at])
  end
end
