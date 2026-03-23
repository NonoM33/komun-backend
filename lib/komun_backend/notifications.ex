defmodule KomunBackend.Notifications do
  @moduledoc """
  Dispatches push notifications to users via Firebase Cloud Messaging.

  Enqueues Oban jobs so delivery is async and retried on failure.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Notifications.Jobs.SendPushNotificationJob

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc "Send a push notification to a single user (no-op if no push tokens)."
  def send_to_user(%User{push_tokens: tokens}, title, body, data \\ %{})
      when is_list(tokens) and tokens != [] do
    %{tokens: tokens, title: title, body: body, data: stringify_values(data)}
    |> SendPushNotificationJob.new()
    |> Oban.insert()
  end

  def send_to_user(_user, _title, _body, _data), do: :ok

  @doc "Send a push notification to all active members of a building with push tokens."
  def send_to_building(building_id, title, body, data \\ %{}) do
    tokens =
      from(m in BuildingMember,
        where: m.building_id == ^building_id and m.is_active == true,
        join: u in User,
        on: u.id == m.user_id,
        where: u.push_tokens != ^[],
        select: u.push_tokens
      )
      |> Repo.all()
      |> List.flatten()
      |> Enum.uniq()

    if tokens != [] do
      %{tokens: tokens, title: title, body: body, data: stringify_values(data)}
      |> SendPushNotificationJob.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # FCM data payload values must be strings
  defp stringify_values(data) do
    Map.new(data, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
end
