defmodule KomunBackend.Repo.Migrations.RelaxUserFkNullability do
  use Ecto.Migration

  # Several tables carry `NOT NULL` on a user FK that is declared with
  # `on_delete: :nilify_all` — the two are contradictory, so deleting any
  # author / reporter / commenter fails at the DB layer with
  # "null value in column violates not-null constraint".
  #
  # Relax the NOT NULL so super_admins can actually delete accounts. The
  # app code already treats these as optional (we render "[utilisateur
  # supprimé]" when nil).
  def up do
    alter table(:incidents) do
      modify :reporter_id, :binary_id, null: true
    end

    alter table(:incident_comments) do
      modify :author_id, :binary_id, null: true
    end

    alter table(:announcements) do
      modify :author_id, :binary_id, null: true
    end
  end

  def down do
    # Don't re-apply NOT NULL: the data model may already contain nil
    # references and flipping it back would break the migration.
    :ok
  end
end
