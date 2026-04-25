defmodule KomunBackend.Battles.AdvanceJob do
  @moduledoc """
  Job Oban qui fait avancer une battle — clôture le round courant et
  soit ouvre le suivant, soit déclare le gagnant final.

  Schedulé au moment de l'ouverture d'un round avec
  `scheduled_at: ends_at`. La file `:default` suffit (impact opérationnel
  faible, pas de criticité particulière).

  Idempotent : `Battles.advance_battle!/1` no-op si la battle est déjà
  finished ou si le round courant est déjà clos. Donc Oban peut retry
  sans effet de bord.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"battle_id" => battle_id}}) do
    case KomunBackend.Battles.advance_battle!(battle_id) do
      {:noop, _battle} ->
        :ok

      {:finished, battle} ->
        Logger.info("[battles] battle #{battle.id} finished, winner: #{battle.winning_option_label}")
        :ok

      {:advanced, battle} ->
        Logger.info(
          "[battles] battle #{battle.id} advanced to round #{battle.current_round}"
        )

        :ok
    end
  end
end
