defmodule KomunBackend.Repo.Migrations.AddScreenshotUrlsToImprovementTickets do
  use Ecto.Migration

  @moduledoc """
  Permet à l'auteur d'un ticket de feedback d'attacher des captures
  d'écran (utile pour décrire un bug visuel sans avoir à passer par
  l'équipe support).

  Pas de table dédiée : tableau de chemins relatifs sur disque, comme
  `incidents.photo_urls`. Suffisant pour le besoin actuel — on n'a
  pas besoin de métadonnées par capture.
  """

  def change do
    alter table(:improvement_tickets) do
      add :screenshot_urls, {:array, :string}, default: [], null: false
    end
  end
end
