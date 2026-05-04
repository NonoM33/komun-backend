defmodule KomunBackend.Events.EventContribution do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "event_contributions" do
    field :title, :string

    field :category, Ecto.Enum,
      values: [:entree, :plat, :dessert, :boisson, :materiel, :autre],
      default: :autre

    field :needed_quantity, :integer

    # Ordre d'affichage côté UI. Permet à l'orga de réorganiser ses
    # rubriques (drag & drop). Plus la valeur est petite, plus la
    # rubrique est haut. Pas d'unicité forcée — en cas d'égalité on
    # tombe sur l'ordre par inserted_at en secondaire.
    field :position, :integer, default: 0

    belongs_to :event, KomunBackend.Events.Event
    belongs_to :created_by, KomunBackend.Accounts.User, foreign_key: :created_by_id

    has_many :claims, KomunBackend.Events.EventContributionClaim, foreign_key: :contribution_id

    timestamps(type: :utc_datetime)
  end

  def changeset(contribution, attrs) do
    contribution
    |> cast(attrs, [:event_id, :title, :category, :needed_quantity, :created_by_id, :position])
    |> validate_required([:event_id, :title, :created_by_id])
    |> validate_length(:title, min: 1, max: 120)
    |> validate_needed_quantity()
  end

  defp validate_needed_quantity(cs) do
    case get_field(cs, :needed_quantity) do
      nil -> cs
      n when is_integer(n) and n > 0 and n <= 999 -> cs
      _ -> add_error(cs, :needed_quantity, "doit être un entier entre 1 et 999")
    end
  end
end
