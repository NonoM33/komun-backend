defmodule KomunBackend.Notifications.Jobs.SendPushNotificationJob do
  use Oban.Worker, queue: :push_notifications, max_attempts: 3

  @fcm_url "https://fcm.googleapis.com/v1/projects/#{System.get_env("FCM_PROJECT_ID", "komun")}/messages:send"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tokens" => tokens, "title" => title, "body" => body} = args}) do
    server_key = System.get_env("FCM_SERVER_KEY")

    Enum.each(tokens, fn token ->
      payload = %{
        message: %{
          token: token,
          notification: %{title: title, body: body},
          data: Map.get(args, "data", %{})
        }
      }

      Req.post(@fcm_url,
        json: payload,
        headers: [
          {"Authorization", "Bearer #{server_key}"},
          {"Content-Type", "application/json"}
        ]
      )
    end)

    :ok
  end
end
