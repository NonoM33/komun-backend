defmodule KomunBackend.Buildings.Lot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lots" do
    field :number, :string
    field :type, Ecto.Enum, values: [:apartment, :parking, :storage, :commercial, :common]
    field :floor, :integer
    field :area_sqm, :decimal
    field :tantieme, :decimal
    field :is_occupied, :boolean, default: false

    # Adjacency overrides — laissés à nil quand la convention de numérotation
    # suffit (ex. "2003" → en dessous = "1003"). Le syndic peut forcer un
    # voisinage spécifique via /admin/floor-map quand la convention casse.
    field :neighbor_lot_ids, {:array, :binary_id}, default: []

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :owner, KomunBackend.Accounts.User, foreign_key: :owner_id
    belongs_to :tenant, KomunBackend.Accounts.User, foreign_key: :tenant_id
    belongs_to :unit_below, __MODULE__, foreign_key: :unit_below_lot_id
    belongs_to :unit_above, __MODULE__, foreign_key: :unit_above_lot_id

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:number, :type, :floor, :area_sqm, :tantieme, :is_occupied,
                    :building_id, :owner_id, :tenant_id])
    |> validate_required([:number, :type, :building_id])
  end

  @doc """
  Changeset dédié aux overrides d'adjacence — utilisé uniquement par
  `PATCH /lots/:id/adjacency` (admin syndic). On l'isole pour éviter qu'un
  endpoint d'édition générique ne touche à l'adjacence par accident.
  """
  def adjacency_changeset(lot, attrs) do
    lot
    |> cast(attrs, [:unit_below_lot_id, :unit_above_lot_id, :neighbor_lot_ids])
    |> validate_change(:unit_below_lot_id, fn :unit_below_lot_id, value ->
      if value == lot.id, do: [unit_below_lot_id: "ne peut pas être le lot lui-même"], else: []
    end)
    |> validate_change(:unit_above_lot_id, fn :unit_above_lot_id, value ->
      if value == lot.id, do: [unit_above_lot_id: "ne peut pas être le lot lui-même"], else: []
    end)
  end
end
