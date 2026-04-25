defmodule KomunBackend.Audit.RoleAuditEntry do
  @moduledoc """
  Une ligne d'audit pour une mutation de rôle. Voir
  `priv/repo/migrations/20260425100000_create_role_audit_log.exs` pour la
  sémantique des champs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @scopes ~w(global building)
  @sources ~w(admin_panel join_by_code magic_link_signup release_boot manual)

  schema "role_audit_log" do
    field :scope, :string
    field :old_role, :string
    field :new_role, :string
    field :source, :string
    field :metadata, :map, default: %{}

    belongs_to :user, KomunBackend.Accounts.User
    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :actor, KomunBackend.Accounts.User, foreign_key: :actor_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :user_id,
      :building_id,
      :scope,
      :old_role,
      :new_role,
      :actor_id,
      :source,
      :metadata
    ])
    |> validate_required([:scope, :source])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:source, @sources)
  end
end
