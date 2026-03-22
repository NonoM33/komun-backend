defmodule KomunBackendWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :komun_backend

  @session_options [
    store: :cookie,
    key: "_komun_key",
    signing_salt: "QbFsJsIO",
    same_site: "Lax"
  ]

  # Phoenix Channels WebSocket
  socket "/socket", KomunBackendWeb.UserSocket,
    websocket: [connect_info: [:peer_data, :x_headers]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :komun_backend,
    gzip: not code_reloading?,
    only: KomunBackendWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :komun_backend
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # CORS — allow Flutter clients (origin: "*" means allow any)
  plug CORSPlug,
    origin: ["*"],
    max_age: 86400,
    methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug KomunBackendWeb.Router
end
