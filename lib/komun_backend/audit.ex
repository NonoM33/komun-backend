defmodule KomunBackend.Audit do
  @moduledoc """
  Persistance des mutations de rôle.

  Toutes les mutations qui changent un rôle (global ou building) doivent
  appeler `record_role_change/1`. C'est l'unique source de vérité pour
  comprendre **a posteriori** qui a fait quoi quand — particulièrement
  utile quand un bug récurrent (cf. "rôles disparus au redéploiement")
  se manifeste sans qu'on ait de log.

  Le `record_role_change/1` retourne `:ok` même si l'insert échoue : on
  ne veut **jamais** qu'une mutation utile soit annulée à cause d'un
  problème de logging. L'erreur est journalisée via `Logger.error/1`.
  """

  require Logger

  alias KomunBackend.Repo
  alias KomunBackend.Audit.RoleAuditEntry

  @type role :: atom() | String.t() | nil
  @type scope :: :global | :building
  @type source ::
          :admin_panel
          | :join_by_code
          | :magic_link_signup
          | :release_boot
          | :manual

  @doc """
  Persist une mutation de rôle. Retourne toujours `:ok`.

  Champs attendus dans la map :
  - `:scope` (atom `:global` | `:building`) — obligatoire
  - `:source` (atom, voir `@type source`) — obligatoire
  - `:user_id` (binary_id) — sujet de la mutation
  - `:building_id` (binary_id, nil pour `:global`)
  - `:old_role` / `:new_role` — atom, string ou nil
  - `:actor_id` — qui a déclenché la mutation (nil = self-service)
  - `:metadata` — map libre (ex: `%{request_id: "..."}`)
  """
  @spec record_role_change(map()) :: :ok
  def record_role_change(attrs) when is_map(attrs) do
    normalized = %{
      scope: attrs |> Map.get(:scope) |> to_str(),
      source: attrs |> Map.get(:source) |> to_str(),
      user_id: Map.get(attrs, :user_id),
      building_id: Map.get(attrs, :building_id),
      actor_id: Map.get(attrs, :actor_id),
      old_role: attrs |> Map.get(:old_role) |> to_str(),
      new_role: attrs |> Map.get(:new_role) |> to_str(),
      metadata: Map.get(attrs, :metadata, %{})
    }

    Logger.warning(
      "[role_audit] scope=#{normalized.scope} source=#{normalized.source} " <>
        "user=#{normalized.user_id} building=#{normalized.building_id} " <>
        "old=#{normalized.old_role} new=#{normalized.new_role} " <>
        "actor=#{normalized.actor_id}"
    )

    case %RoleAuditEntry{} |> RoleAuditEntry.changeset(normalized) |> Repo.insert() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "[role_audit] insert failed: #{inspect(changeset.errors)} attrs=#{inspect(normalized)}"
        )

        :ok
    end
  end

  defp to_str(nil), do: nil
  defp to_str(value) when is_atom(value), do: Atom.to_string(value)
  defp to_str(value) when is_binary(value), do: value
  defp to_str(other), do: inspect(other)
end
