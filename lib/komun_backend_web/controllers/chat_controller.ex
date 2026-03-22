defmodule KomunBackendWeb.ChatController do
  use KomunBackendWeb, :controller
  alias KomunBackend.Auth.Guardian

  @stream_api_key System.get_env("STREAM_API_KEY") || "PLACEHOLDER_API_KEY"
  @stream_secret System.get_env("STREAM_SECRET") || "PLACEHOLDER_SECRET"

  def token(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    user_id = to_string(user.id)

    # Generate Stream user token (HS256 JWT with user_id claim)
    # Stream tokens: header {"alg":"HS256","typ":"JWT"} + payload {"user_id":"..."}
    token = generate_stream_token(user_id)

    json(conn, %{
      data: %{
        token: token,
        user_id: user_id,
        api_key: @stream_api_key
      }
    })
  end

  defp generate_stream_token(user_id) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(%{"user_id" => user_id}), padding: false)
    signing_input = "#{header}.#{payload}"

    signature =
      :crypto.mac(:hmac, :sha256, @stream_secret, signing_input)
      |> Base.url_encode64(padding: false)

    "#{signing_input}.#{signature}"
  end
end
