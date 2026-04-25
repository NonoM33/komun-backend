defmodule KomunBackend.Release do
  @moduledoc """
  Tâches de release lancées par le Dockerfile au boot du conteneur.

  Aujourd'hui c'est uniquement `migrate/0` (cf. `Dockerfile:53` qui fait
  `bin/komun_backend eval 'KomunBackend.Release.migrate()' && start`).

  On instrumente avant/après les migrations avec :
  - le numéro de release Mix (pour corréler avec un commit côté Coolify)
  - le compte de `building_members` actifs avant ET après les
    migrations.

  But concret : à la prochaine occurrence du bug "rôles disparus au
  redéploiement", on saura immédiatement si la perte vient des
  migrations elles-mêmes (count diminue dans la même release) ou d'une
  action post-deploy (count stable au boot, mais variations plus tard
  visibles dans `role_audit_log`).
  """

  require Logger

  @app :komun_backend

  def migrate do
    load_app()

    log("starting migrate/0", before_count: nil)
    before_counts = safe_member_counts()
    log("pre-migrate snapshot", member_counts: before_counts)

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    after_counts = safe_member_counts()
    log("post-migrate snapshot", member_counts: after_counts)

    diff = diff_counts(before_counts, after_counts)

    if diff == %{} do
      log("migrate/0 done — no membership change detected", [])
    else
      Logger.warning(
        "[release] member counts changed during migration — diff=#{inspect(diff)}"
      )
    end

    :ok
  end

  defp safe_member_counts do
    {:ok, counts, _} =
      Ecto.Migrator.with_repo(KomunBackend.Repo, fn repo ->
        # Récupère le nombre de membres actifs par bâtiment, sans toucher
        # aux schemas Ecto (le repo est démarré juste pour cette query,
        # avant que les migrations n'aient tourné — on évite de dépendre
        # d'un schema qui pourrait être incompatible avec la DB).
        case repo.query(
               """
               SELECT COALESCE(building_id::text, 'null') AS bid, COUNT(*) AS n
               FROM building_members
               WHERE is_active = TRUE
               GROUP BY building_id
               """,
               []
             ) do
          {:ok, %{rows: rows}} ->
            Map.new(rows, fn [bid, n] -> {bid, n} end)

          {:error, _} ->
            %{}
        end
      end)

    counts
  rescue
    # Première migration, table absente, etc. : on ne fait pas planter
    # le boot pour un compteur d'observabilité.
    e ->
      Logger.warning("[release] cannot read member counts: #{inspect(e)}")
      %{}
  end

  defp diff_counts(before_counts, after_counts) do
    keys = MapSet.union(MapSet.new(Map.keys(before_counts)), MapSet.new(Map.keys(after_counts)))

    keys
    |> Enum.reduce(%{}, fn key, acc ->
      b = Map.get(before_counts, key, 0)
      a = Map.get(after_counts, key, 0)

      if a == b do
        acc
      else
        Map.put(acc, key, %{before: b, after: a})
      end
    end)
  end

  defp log(message, metadata) do
    vsn =
      case Application.spec(:komun_backend, :vsn) do
        nil -> "unknown"
        v -> to_string(v)
      end

    Logger.info("[release] vsn=#{vsn} #{message} #{inspect(metadata)}")
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
