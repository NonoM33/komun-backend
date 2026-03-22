defmodule KomunBackend.Repo.Migrations.MakeBuildingOrganizationOptional do
  use Ecto.Migration

  def change do
    alter table(:buildings) do
      modify :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: true,
        from: references(:organizations, type: :binary_id, on_delete: :delete_all)
    end
  end
end
