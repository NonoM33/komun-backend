defmodule KomunBackend.Auth do
  @moduledoc """
  Helpers d'autorisation transverses (rôles globaux, vérifications de
  privilèges côté plateforme).

  Les vérifications **scoped résidence/bâtiment** continuent de vivre
  dans les contextes métier (`Incidents.privileged?/2`, etc.) — ce
  module ne gère QUE les rôles globaux Komun-side.

  Le rôle `:super_admin` est superset de `:komun_staff` : tout ce qu'un
  staff peut faire, le super_admin peut le faire (et plus).
  """

  alias KomunBackend.Accounts.User

  @komun_staff_roles [:komun_staff, :super_admin]

  @doc """
  Renvoie `true` si l'utilisateur appartient à l'équipe Komun
  (CSM, support, ops, ou super_admin).

  Renvoie `false` pour `nil`, ou pour un user sans rôle (defensive).
  """
  @spec komun_staff?(%User{} | nil) :: boolean()
  def komun_staff?(%User{role: role}) when role in @komun_staff_roles, do: true
  def komun_staff?(_), do: false

  @doc """
  Liste des rôles considérés comme "staff Komun".
  Exposée pour les besoins des plugs / contrôleurs.
  """
  @spec komun_staff_roles() :: [atom()]
  def komun_staff_roles, do: @komun_staff_roles
end
