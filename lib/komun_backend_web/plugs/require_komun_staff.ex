defmodule KomunBackendWeb.Plugs.RequireKomunStaff do
  @moduledoc """
  Plug qui exige un user authentifié avec un rôle Komun-side
  (`:komun_staff` ou `:super_admin`). Halt en 403 sinon.

  À placer **après** la pipeline d'auth (Guardian + ApiTokenAuth) :
  on assume que `Guardian.Plug.current_resource/1` est hydraté ou nil.

  Réponse 403 standardisée :

      %{"error" => "forbidden", "reason" => "komun_staff_required"}
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias KomunBackend.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    user = Guardian.Plug.current_resource(conn)

    if Auth.komun_staff?(user) do
      conn
    else
      conn
      |> put_status(403)
      |> json(%{error: "forbidden", reason: "komun_staff_required"})
      |> halt()
    end
  end
end
