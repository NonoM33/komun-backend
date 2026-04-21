defmodule KomunBackend.Repo.Migrations.AddProfileFieldsToUsers do
  use Ecto.Migration

  # Residents declare their relation to their lot right after joining a
  # residence. These live on users (not on building_members) so they survive
  # if the user is linked to several buildings — the syndic still needs to
  # know who is the decision-maker in AG.
  def change do
    alter table(:users) do
      add :status, :string
      add :apartment_number, :string
      add :floor, :integer
    end

    create index(:users, [:status])
  end
end
