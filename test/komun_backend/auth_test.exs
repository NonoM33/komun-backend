defmodule KomunBackend.AuthTest do
  @moduledoc """
  TICKET-1.1 — Helper `KomunBackend.Auth.komun_staff?/1`.

  Doit renvoyer `true` pour les rôles `:komun_staff` et `:super_admin`
  (super_admin est superset), `false` pour tout le reste, y compris
  `nil` (pas de session).
  """

  use ExUnit.Case, async: true

  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth

  describe "komun_staff?/1" do
    test "renvoie true pour un user :komun_staff" do
      assert Auth.komun_staff?(%User{role: :komun_staff})
    end

    test "renvoie true pour un user :super_admin (superset)" do
      assert Auth.komun_staff?(%User{role: :super_admin})
    end

    test "renvoie false pour les autres rôles métier" do
      for role <- [
            :syndic_manager,
            :syndic_staff,
            :president_cs,
            :membre_cs,
            :coproprietaire,
            :locataire,
            :gardien,
            :prestataire
          ] do
        refute Auth.komun_staff?(%User{role: role}),
               "expected #{role} not to be komun_staff"
      end
    end

    test "renvoie false pour nil (pas de user)" do
      refute Auth.komun_staff?(nil)
    end

    test "renvoie false pour un User sans rôle" do
      refute Auth.komun_staff?(%User{role: nil})
    end
  end
end
