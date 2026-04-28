defmodule KomunBackend.Repo.Migrations.AddInboundAliasToBuildings do
  use Ecto.Migration

  # Adresse de réception email pour la pipeline d'ingestion par
  # webhook Resend. Quand un email est envoyé à
  # `<inbound_alias>@inbound.komun.app`, le webhook crée un brouillon
  # d'incident sur le bâtiment correspondant.
  #
  # Format attendu : slug ASCII minuscule (lettres, chiffres, tirets),
  # 3-32 chars. Validation faite côté schema.
  def change do
    alter table(:buildings) do
      add :inbound_alias, :string
    end

    create unique_index(:buildings, [:inbound_alias],
             where: "inbound_alias IS NOT NULL")
  end
end
