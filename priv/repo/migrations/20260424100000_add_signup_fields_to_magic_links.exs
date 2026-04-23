defmodule KomunBackend.Repo.Migrations.AddSignupFieldsToMagicLinks do
  use Ecto.Migration

  def change do
    alter table(:magic_links) do
      add :join_code, :string
      add :first_name, :string
      add :last_name, :string
    end
  end
end
