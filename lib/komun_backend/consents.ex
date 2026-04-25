defmodule KomunBackend.Consents do
  @moduledoc """
  Consent logs — CNIL/RGPD proof of opt-in/opt-out for cookies, trackers, etc.

  Bump `policy_version/0` in sync with the frontend constant whenever the
  privacy policy materially changes. Clients with an older version in the
  cookie will be shown the banner again.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Consents.ConsentLog

  @policy_version "2026-04-24"

  def policy_version, do: @policy_version

  def record_consent(attrs) do
    %ConsentLog{}
    |> ConsentLog.changeset(Map.put_new(attrs, "policy_version", @policy_version))
    |> Repo.insert()
  end

  def latest_for_user(user_id) when is_binary(user_id) do
    ConsentLog
    |> where([l], l.user_id == ^user_id)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def latest_for_visitor(visitor_id) when is_binary(visitor_id) do
    ConsentLog
    |> where([l], l.visitor_id == ^visitor_id)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end
end
