defmodule KomunBackend.Repo.Migrations.AddTargetAddressToDoleances do
  use Ecto.Migration

  def change do
    alter table(:doleances) do
      add :target_address, :text
    end
  end
end
