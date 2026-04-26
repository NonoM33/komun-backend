defmodule KomunBackend.Repo.Migrations.AddCodeHashToMagicLinks do
  use Ecto.Migration

  # Le `code_hash` permet d'authentifier l'utilisateur via un code à
  # 6 chiffres tapé manuellement dans la PWA. Indispensable sur iOS où
  # un clic dans Mail ouvre Safari (pas l'app standalone), ce qui pose
  # les tokens dans le mauvais contexte localStorage. Avec un code que
  # l'utilisateur recopie, il reste de bout en bout dans la PWA.
  #
  # `attempts_count` borne les essais (5 max → on invalide le lien)
  # pour ne pas exposer un secret 6 digits au brute-force.
  def change do
    alter table(:magic_links) do
      add :code_hash, :string
      add :attempts_count, :integer, default: 0, null: false
    end
  end
end
