defmodule KomunBackend.Organizations.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :type, Ecto.Enum, values: [:syndic, :autonomous], default: :autonomous
    field :siret, :string
    field :email, :string
    field :phone, :string
    field :logo_url, :string
    field :address, :map
    field :subscription_plan, Ecto.Enum,
      values: [:free, :starter, :pro, :enterprise], default: :free
    field :subscription_expires_at, :utc_datetime
    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string
    field :settings, :map, default: %{}
    field :is_active, :boolean, default: true

    has_many :buildings, KomunBackend.Buildings.Building
    has_many :members, KomunBackend.Accounts.User, foreign_key: :organization_id

    timestamps(type: :utc_datetime)
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug, :type, :siret, :email, :phone, :logo_url,
                    :address, :subscription_plan, :settings])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 120)
    |> put_slug()
    |> unique_constraint(:slug)
  end

  defp put_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name ->
        slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-")
        put_change(changeset, :slug, slug)
    end
  end
end
