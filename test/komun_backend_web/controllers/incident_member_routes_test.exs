defmodule KomunBackendWeb.IncidentMemberRoutesTest do
  @moduledoc """
  Régression du 2026-04-25 : `POST /buildings/:b/incidents/:incident_id/confirm-ai`,
  `DELETE …/confirm-ai` et `PUT …/ai-answer` retournaient 400 (Bad Request)
  côté UI parce que les fonctions du contrôleur pattern-matchaient sur
  `"id"` alors que Phoenix passe `"incident_id"` pour les routes member
  définies à l'intérieur d'un bloc `resources do … end`.

  Ce test bloque la régression sur deux fronts :
  1. Statique : le code source n'utilise plus `"id"` dans les pattern
     matches de ces fonctions.
  2. Dynamique : `Phoenix.Router.route_info/4` confirme que les routes
     vivent bien sous le param `:incident_id`.
  """

  use ExUnit.Case, async: true

  alias KomunBackendWeb.Router

  @member_paths [
    {"POST",
     "/api/v1/buildings/00000000-0000-0000-0000-000000000001/incidents/00000000-0000-0000-0000-000000000002/confirm-ai"},
    {"DELETE",
     "/api/v1/buildings/00000000-0000-0000-0000-000000000001/incidents/00000000-0000-0000-0000-000000000002/confirm-ai"},
    {"PUT",
     "/api/v1/buildings/00000000-0000-0000-0000-000000000001/incidents/00000000-0000-0000-0000-000000000002/ai-answer"}
  ]

  test "Phoenix nomme bien le path param :incident_id pour les member routes" do
    for {method, path} <- @member_paths do
      info = Router.route_info(method, path, "stg-api.komun.app")

      assert info.path_params["incident_id"] == "00000000-0000-0000-0000-000000000002",
             "Pour #{method} #{path}, Phoenix doit fournir :incident_id (got: #{inspect(info.path_params)})"

      refute Map.has_key?(info.path_params, "id"),
             "Phoenix ne doit PAS aussi exposer :id pour ces routes (got: #{inspect(info.path_params)})"
    end
  end

  test "le contrôleur pattern-matche sur incident_id (et plus sur id)" do
    source =
      File.read!(
        Path.join([
          File.cwd!(),
          "lib/komun_backend_web/controllers/incident_controller.ex"
        ])
      )

    for fn_name <- ~w(confirm_ai_answer unconfirm_ai_answer update_ai_answer) do
      refute source =~ ~r/def #{fn_name}\(conn,\s*%\{[^}]*"id"\s*=>/,
             "#{fn_name} ne doit PAS pattern-matcher sur \"id\" — Phoenix passe \"incident_id\" pour les routes member nested"

      assert source =~ ~r/def #{fn_name}\(conn,\s*%\{[^}]*"incident_id"\s*=>/,
             "#{fn_name} doit pattern-matcher sur \"incident_id\""
    end
  end
end
