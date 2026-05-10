defmodule KomunBackend.Events.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "events" do
    field :title, :string
    field :description, :string
    field :cover_image_url, :string

    field :kind, Ecto.Enum,
      values: [:festif, :reunion_conseil, :atelier, :ag, :autre],
      default: :festif

    field :status, Ecto.Enum,
      values: [:draft, :published, :cancelled, :completed],
      default: :draft

    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime

    field :location_label, :string
    field :location_details, :string

    field :max_participants, :integer
    field :requires_registration, :boolean, default: true
    field :allow_plus_ones, :boolean, default: true
    field :kid_friendly, :boolean, default: true

    field :cancelled_at, :utc_datetime
    field :cancelled_reason, :string

    # Public concerné — vide = toute la résidence. Buckets connus :
    # "conseil" | "proprietaire" | "bailleur" | "locataire".
    # Filtre s'applique aux EMAILS / NOTIFICATIONS (pas à la visibilité).
    field :target_resident_types, {:array, :string}, default: []

    # Liens vers les jobs Oban planifiés à la publication. Best-effort —
    # nil tant qu'on n'a pas réussi à enqueue (ex. event encore en draft).
    field :reminder_job_id, :integer
    field :gap_job_id, :integer
    field :thank_you_job_id, :integer

    belongs_to :residence, KomunBackend.Residences.Residence
    belongs_to :creator, KomunBackend.Accounts.User, foreign_key: :creator_id

    has_many :participations, KomunBackend.Events.EventParticipation
    has_many :building_scopes, KomunBackend.Events.EventBuildingScope
    has_many :organizers, KomunBackend.Events.EventOrganizer
    has_many :contributions, KomunBackend.Events.EventContribution
    has_many :comments, KomunBackend.Events.EventComment
    has_many :email_blasts, KomunBackend.Events.EventEmailBlast

    timestamps(type: :utc_datetime)
  end

  @castable [
    :title,
    :description,
    :cover_image_url,
    :kind,
    :status,
    :starts_at,
    :ends_at,
    :location_label,
    :location_details,
    :max_participants,
    :requires_registration,
    :allow_plus_ones,
    :kid_friendly,
    :residence_id,
    :creator_id,
    :reminder_job_id,
    :gap_job_id,
    :thank_you_job_id,
    :target_resident_types
  ]

  @valid_resident_types ~w(conseil proprietaire bailleur locataire)

  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> validate_required([:title, :starts_at, :ends_at, :residence_id, :creator_id])
    |> validate_length(:title, min: 3, max: 200)
    |> validate_length(:location_label, max: 200)
    |> validate_max_participants()
    |> validate_chronology()
    |> validate_resident_types()
  end

  defp validate_resident_types(cs) do
    case get_field(cs, :target_resident_types) do
      nil ->
        cs

      list when is_list(list) ->
        bad = Enum.reject(list, &(&1 in @valid_resident_types))

        if bad == [] do
          cs
        else
          add_error(cs, :target_resident_types,
            "valeurs invalides : #{Enum.join(bad, ", ")} (autorisées : #{Enum.join(@valid_resident_types, ", ")})"
          )
        end

      _ ->
        add_error(cs, :target_resident_types, "doit être une liste")
    end
  end

  @doc """
  Buckets de type d'habitant pour un user, sur le contexte d'une
  résidence donnée. Permet de matcher un user contre `target_resident_types`
  d'un event sans dupliquer la logique entre l'envoi d'email, le push
  J-1 et l'audit visuel. Un user peut appartenir à plusieurs buckets
  (ex. propriétaire-occupant qui est AUSSI au conseil syndical).
  """
  def resident_buckets(%{role: role, status: status}, residence_role) do
    out = []

    out =
      if role in [:president_cs, :membre_cs] or residence_role in [:president_cs, :membre_cs],
        do: ["conseil" | out],
        else: out

    out =
      case status do
        :owner_occupant -> ["proprietaire" | out]
        :owner_landlord -> ["bailleur" | out]
        :tenant -> ["locataire" | out]
        _ -> out
      end

    out =
      case role do
        :coproprietaire -> if "proprietaire" in out, do: out, else: ["proprietaire" | out]
        :locataire -> if "locataire" in out, do: out, else: ["locataire" | out]
        _ -> out
      end

    Enum.uniq(out)
  end

  def resident_buckets(_user, _role), do: []

  def valid_resident_types, do: @valid_resident_types

  # `:cancelled_at` / `:cancelled_reason` ne passent QUE par le
  # `cancel_changeset/2` ci-dessous. Évite qu'un PATCH générique annule
  # l'event en envoyant ces champs « par accident » dans son payload.
  def cancel_changeset(event, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    event
    |> cast(%{cancelled_at: now, cancelled_reason: reason, status: :cancelled},
            [:cancelled_at, :cancelled_reason, :status])
  end

  defp validate_max_participants(cs) do
    case get_field(cs, :max_participants) do
      nil -> cs
      n when is_integer(n) and n > 0 -> cs
      _ -> add_error(cs, :max_participants, "doit être un entier strictement positif")
    end
  end

  defp validate_chronology(cs) do
    starts = get_field(cs, :starts_at)
    ends = get_field(cs, :ends_at)

    cond do
      is_nil(starts) or is_nil(ends) ->
        cs

      DateTime.compare(ends, starts) in [:gt, :eq] ->
        cs

      true ->
        add_error(cs, :ends_at, "doit être postérieur ou égal à starts_at")
    end
  end
end
