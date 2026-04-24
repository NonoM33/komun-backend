defmodule KomunBackend.Repo.Migrations.CreateRoleAuditLog do
  use Ecto.Migration

  @moduledoc """
  Trace **toutes** les mutations de rôle (global ou résidence) — créations,
  updates, suppressions. On a un bug récurrent en prod où des membres
  perdent leur rôle au moment d'un redéploiement, et sans table d'audit
  on ne peut pas répondre en 30s à "qui a changé le rôle de X, quand,
  via quel chemin".

  Conventions :
  - `scope` ∈ `"global"` (mutation sur `users.role`) | `"building"`
    (mutation sur `building_members.role`).
  - `old_role` = nil quand c'est la création du rôle.
  - `new_role` = nil quand c'est une suppression.
  - `actor_id` = qui a déclenché le changement (super_admin, ou nil si
    c'est l'utilisateur lui-même via flow de signup / join).
  - `source` = par où est arrivée la mutation : `"admin_panel"`,
    `"join_by_code"`, `"magic_link_signup"`, etc.
  - FKs en `nilify_all` plutôt que `delete_all` : on garde les lignes
    d'audit même après suppression d'un user / building, pour l'analyse
    post-incident.
  """

  def change do
    create table(:role_audit_log, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :building_id, references(:buildings, type: :binary_id, on_delete: :nilify_all)
      add :scope, :string, null: false
      add :old_role, :string
      add :new_role, :string
      add :actor_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :source, :string, null: false
      add :metadata, :map, default: %{}, null: false

      add :inserted_at, :utc_datetime, null: false, default: fragment("NOW()")
    end

    create index(:role_audit_log, [:user_id])
    create index(:role_audit_log, [:building_id])
    create index(:role_audit_log, [:inserted_at])
  end
end
