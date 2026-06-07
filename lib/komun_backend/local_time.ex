defmodule KomunBackend.LocalTime do
  @moduledoc """
  Conversion des datetimes UTC (stockés en base) vers l'heure locale
  française pour l'affichage (previews Open Graph, emails, push).

  Les colonnes sont en `:utc_datetime` : un événement « jeudi 8h » est
  persisté `06:00:00Z` en été (UTC+2). Sans conversion, on affiche « 06:00 »
  au voisin — d'où ce helper centralisé, DST-safe via la base `tz`.
  """

  @zone "Europe/Paris"

  @doc """
  Bascule un `DateTime` UTC vers `Europe/Paris`. Si la conversion échoue
  (base tz absente, zone inconnue), on retombe sur le datetime d'origine
  plutôt que de crasher la preview / l'email.
  """
  def to_local(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, @zone) do
      {:ok, local} -> local
      {:error, _} -> dt
    end
  end

  def to_local(other), do: other
end
