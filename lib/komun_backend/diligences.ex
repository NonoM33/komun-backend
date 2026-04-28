defmodule KomunBackend.Diligences do
  @moduledoc """
  Contexte public des diligences — dossiers de suivi en 9 étapes pour
  les troubles anormaux du voisinage.

  Toutes les fonctions de ce module supposent que l'appelant a déjà été
  vérifié comme membre privilégié du bâtiment (syndic, conseil syndical
  ou super_admin). Le gating est fait dans le controller via
  `authorize_privileged/3` — voir `KomunBackendWeb.DiligenceController`.

  ## Pourquoi tout passe par le contexte

  - La création d'une diligence doit insérer la diligence ET ses 9
    `diligence_steps` dans la même transaction (sinon une diligence
    pourrait se retrouver sans étapes si l'insert échoue à mi-chemin).
  - Les courriers générés par IA (`set_letter/3`) ont une porte
    d'entrée dédiée pour pouvoir versionner / logger la génération
    sans confondre avec une édition manuelle.
  """

  import Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Accounts.User
  alias KomunBackend.Diligences.{Diligence, DiligenceStep, DiligenceFile, Steps}

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  @doc """
  Vrai si `user` peut accéder aux diligences du bâtiment. Aligné sur la
  logique `Incidents.privileged?/2` — duplication délibérée pour rester
  indépendant des autres contextes.
  """
  def privileged?(_building_id, nil), do: false
  def privileged?(_building_id, %User{role: :super_admin}), do: true

  def privileged?(building_id, %User{} = user) do
    member_role = Buildings.get_member_role(building_id, user.id)
    user.role in @privileged_roles or member_role in @privileged_roles
  end

  @doc """
  Liste les diligences d'un bâtiment, plus récentes d'abord. La
  visibilité étant uniforme (CS + syndic seuls), pas de filtre
  spécifique côté liste — c'est le controller qui rejette les
  appelants non privilégiés.
  """
  def list_diligences(building_id, filters \\ %{}) do
    from(d in Diligence,
      where: d.building_id == ^building_id,
      order_by: [desc: d.inserted_at],
      preload: [:created_by, :linked_incident, steps: ^step_order(), files: ^file_order()]
    )
    |> apply_filter(:status, filters["status"])
    |> apply_filter(:linked_incident_id, filters["linked_incident_id"])
    |> apply_drafts_visibility(filters)
    |> Repo.all()
  end

  defp apply_filter(q, _field, nil), do: q
  defp apply_filter(q, _field, ""), do: q
  defp apply_filter(q, :status, v), do: where(q, [d], d.status == ^v)

  defp apply_filter(q, :linked_incident_id, v),
    do: where(q, [d], d.linked_incident_id == ^v)

  # Diligences = 100% admin-only (controller rejette les non-privilégiés
  # via `authorize_privileged/3`). Tous les appelants ici peuvent donc
  # voir les brouillons. On garde la fonction pour symétrie avec les
  # contextes Incidents/Doleances qui ont une UX mixte.
  defp apply_drafts_visibility(q, _filters), do: q

  defp step_order, do: from(s in DiligenceStep, order_by: [asc: s.step_number])
  defp file_order, do: from(f in DiligenceFile, order_by: [desc: f.inserted_at])

  @doc """
  Liste les diligences rattachées à un incident donné. Réservé CS+syndic
  côté UX (le gating est dans le controller appelant — on ne sert que
  des briefs aux non-privilégiés via `linked_diligences` côté incident).
  """
  def list_by_incident(incident_id) do
    from(d in Diligence,
      where: d.linked_incident_id == ^incident_id,
      preload: [:created_by],
      order_by: [desc: d.inserted_at]
    )
    |> Repo.all()
  end

  def get_diligence!(id) do
    Diligence
    |> Repo.get!(id)
    |> Repo.preload([
      :created_by,
      :linked_incident,
      steps: from(s in DiligenceStep, order_by: [asc: s.step_number]),
      files: from(f in DiligenceFile, order_by: [desc: f.inserted_at])
    ])
  end

  def get_diligence(id) do
    case Repo.get(Diligence, id) do
      nil -> nil
      diligence -> Repo.preload(diligence, [:created_by, :linked_incident, :steps, :files])
    end
  end

  @doc """
  Crée une diligence ET ses 9 étapes (toutes en `pending`) en une
  seule transaction. La transaction est volontairement explicite
  plutôt qu'un `Multi` pour rester lisible — il n'y a que deux étapes
  à séquencer.

  L'étape 1 n'est pas pré-marquée `in_progress` : on laisse l'utilisateur
  cliquer dessus pour qu'on ait un horodatage de "vraie" prise en main.
  """
  def create_diligence(building_id, %User{} = user, attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.merge(%{"building_id" => building_id, "created_by_id" => user.id})

    Repo.transaction(fn ->
      with {:ok, diligence} <-
             %Diligence{}
             |> Diligence.create_changeset(attrs)
             |> Repo.insert(),
           :ok <- insert_initial_steps(diligence) do
        get_diligence!(diligence.id)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # On accepte indifféremment les attrs avec clés string (venant du
  # controller Plug) ou atom (venant des tests). Plus pratique pour
  # les tests qui n'ont pas besoin de tout stringifier.
  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp insert_initial_steps(%Diligence{id: diligence_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(Steps.all(), fn %{n: n} ->
        %{
          id: Ecto.UUID.generate(),
          diligence_id: diligence_id,
          step_number: n,
          # Ecto.Enum exige l'atom dans `insert_all` (pas la string).
          status: :pending,
          inserted_at: now,
          updated_at: now
        }
      end)

    case Repo.insert_all(DiligenceStep, rows) do
      {count, _} when count == length(rows) -> :ok
      _ -> {:error, :step_seed_failed}
    end
  end

  def update_diligence(%Diligence{} = diligence, attrs) do
    diligence
    |> Diligence.update_changeset(normalize_attrs(attrs))
    |> Repo.update()
    |> reload_on_success()
  end

  @doc """
  Met à jour une étape spécifique d'une diligence. `step_number` est
  validé en amont (1..9). Si l'étape n'existe pas (cas théorique : la
  création a planté à mi-chemin avant la PR), on renvoie `{:error, :not_found}`.
  """
  def update_step(diligence_id, step_number, attrs) do
    if Steps.valid_number?(step_number) do
      case Repo.get_by(DiligenceStep, diligence_id: diligence_id, step_number: step_number) do
        nil ->
          {:error, :not_found}

        %DiligenceStep{} = step ->
          step
          |> DiligenceStep.update_changeset(normalize_attrs(attrs))
          |> Repo.update()
      end
    else
      {:error, :invalid_step_number}
    end
  end

  @doc """
  Persiste un courrier généré (saisine syndic ou mise en demeure) sur
  la diligence. Appelé par `KomunBackend.AI.DiligenceLetter` (PR#3) —
  ne pas exposer directement sur l'API publique.
  """
  def set_letter(%Diligence{} = diligence, kind, text)
      when kind in [:saisine, :mise_en_demeure] do
    diligence
    |> Diligence.letter_changeset(kind, text)
    |> Repo.update()
    |> reload_on_success()
  end

  defp reload_on_success({:ok, %Diligence{id: id}}), do: {:ok, get_diligence!(id)}
  defp reload_on_success(other), do: other

  @doc """
  Attache une pièce justificative (journal, attestation CERFA, photo,
  constat huissier…) à une diligence. Ne valide pas le contenu : c'est
  le controller qui contrôle taille / mime-type avant d'appeler cette
  fonction (séparation des responsabilités — la validation des bytes
  d'upload n'a rien à faire dans le contexte métier).
  """
  def attach_file(diligence_id, %User{} = user, attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.merge(%{
        "diligence_id" => diligence_id,
        "uploaded_by_id" => user.id
      })

    %DiligenceFile{}
    |> DiligenceFile.changeset(attrs)
    |> Repo.insert()
  end

  def get_file!(id), do: Repo.get!(DiligenceFile, id)

  @doc """
  Supprime une pièce justificative (et idéalement le fichier sur disque,
  cf. controller). Renvoyé tel quel pour que le controller puisse
  enchaîner sur le `File.rm/1`.
  """
  def delete_file(%DiligenceFile{} = file), do: Repo.delete(file)

  @doc """
  Liste les utilisateurs privilégiés d'un bâtiment — utile pour les
  notifs futures. Renvoyé en V1 par le controller pour aider le front
  à afficher "Cette diligence est suivie par X, Y, Z".
  """
  def privileged_members(building_id) do
    council_member_roles = [:president_cs, :membre_cs]
    syndic_user_roles = [:super_admin, :syndic_manager, :syndic_staff]

    from(m in BuildingMember,
      join: u in User,
      on: u.id == m.user_id,
      where:
        m.building_id == ^building_id and
          m.is_active == true and
          (m.role in ^council_member_roles or u.role in ^syndic_user_roles),
      select: u,
      distinct: true
    )
    |> Repo.all()
  end
end
