defmodule KomunBackend.AccountsRoleAuditTest do
  @moduledoc """
  Couverture du chemin "super_admin change le rôle global d'un user via
  l'admin panel" : on doit retrouver la mutation dans `role_audit_log`
  avec l'`actor_id` du super_admin et la source `admin_panel`.

  Sans audit log, on ne pouvait pas répondre à "qui a changé le rôle de
  Pascale, quand, depuis où" — d'où le bug "rôles disparus" qui
  redébarquait à chaque release sans qu'on puisse remonter à la cause.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.Accounts
  alias KomunBackend.Accounts.User
  alias KomunBackend.Audit.RoleAuditEntry

  defp insert_user!(role \\ :coproprietaire) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp global_audit(user_id) do
    Repo.all(
      from(e in RoleAuditEntry,
        where: e.user_id == ^user_id and e.scope == "global",
        order_by: [asc: e.inserted_at]
      )
    )
  end

  describe "update_user_role/3" do
    test "trace l'ancien et le nouveau rôle dans role_audit_log" do
      admin = insert_user!(:super_admin)
      target = insert_user!(:coproprietaire)

      assert {:ok, updated} =
               Accounts.update_user_role(target.id, :membre_cs,
                 actor_id: admin.id,
                 source: :admin_panel
               )

      assert updated.role == :membre_cs

      assert [entry] = global_audit(target.id)
      assert entry.scope == "global"
      assert entry.source == "admin_panel"
      assert entry.old_role == "coproprietaire"
      assert entry.new_role == "membre_cs"
      assert entry.actor_id == admin.id
    end

    test "{:error, :not_found} si l'user n'existe pas, sans entrée d'audit" do
      assert {:error, :not_found} =
               Accounts.update_user_role(Ecto.UUID.generate(), :membre_cs)

      assert Repo.aggregate(RoleAuditEntry, :count, :id) == 0
    end

    test "n'écrit pas d'audit si le changeset Repo.update échoue" do
      target = insert_user!()

      assert {:error, _} = Accounts.update_user_role(target.id, :role_inexistant)

      # Aucune mutation persistée → aucune trace.
      assert global_audit(target.id) == []
    end
  end
end
