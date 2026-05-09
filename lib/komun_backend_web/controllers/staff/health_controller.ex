defmodule KomunBackendWeb.Staff.HealthController do
  @moduledoc """
  Health check pour le scope staff.

  Vérifie l'auth + le pipeline `:require_komun_staff` end-to-end.
  Le frontend `staff.komun.app` peut pinger cette route au montage
  pour s'assurer que la session est bien staff (autrement il est
  rejeté en 403 et redirige vers le login).
  """

  use KomunBackendWeb, :controller

  def check(conn, _params) do
    json(conn, %{ok: true, scope: "staff"})
  end
end
