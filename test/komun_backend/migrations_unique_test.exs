defmodule KomunBackend.MigrationsUniqueTest do
  use ExUnit.Case, async: true

  # Régression du 2026-04-25 : deux migrations avec le même timestamp
  # `20260425100000` (`create_role_audit_log` et `add_visibility_to_incidents`)
  # ont été poussées en stg, ce qui a fait crasher le boot Phoenix avec
  # `Ecto.MigrationError: migrations can't be executed, migration version
  # 20260425100000 is duplicated`. Ce test bloque toute future
  # collision dès que `mix test` tourne en CI.
  test "every migration has a unique 14-digit version prefix" do
    migrations_dir = Path.join([File.cwd!(), "priv", "repo", "migrations"])

    versions =
      migrations_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.map(fn name ->
        case Regex.run(~r/^(\d{14})_/, name) do
          [_, ts] -> {ts, name}
          _ -> flunk("migration filename doesn't start with 14-digit timestamp: #{name}")
        end
      end)

    duplicates =
      versions
      |> Enum.group_by(fn {ts, _} -> ts end)
      |> Enum.filter(fn {_ts, files} -> length(files) > 1 end)

    assert duplicates == [], """
    Two or more migrations share the same timestamp prefix:
    #{inspect(duplicates, pretty: true)}

    Renommer l'un des fichiers (et garder le module name interne aligné si besoin).
    """
  end
end
