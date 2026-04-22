defmodule KomunBackendWeb.Router do
  use KomunBackendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug :accepts, ["json"]
    plug KomunBackend.Auth.Pipeline
  end

  pipeline :require_super_admin do
    plug KomunBackendWeb.Plugs.RequireSuperAdmin
  end

  # ── Health check ─────────────────────────────────────────────────────────
  scope "/api", KomunBackendWeb do
    pipe_through :api
    get "/health", HealthController, :check
  end

  # ── Public routes (no auth) ───────────────────────────────────────────────
  scope "/api/v1", KomunBackendWeb do
    pipe_through :api

    post "/auth/magic-link", AuthController, :request_magic_link
    get  "/auth/magic-link/verify", AuthController, :verify_magic_link
    post "/auth/refresh", AuthController, :refresh
    post "/auth/logout", AuthController, :logout

    # Invite info (public — pour afficher le nom de l'immeuble avant connexion)
    get "/invites/:token", InviteController, :show
  end

  # ── Authenticated routes ──────────────────────────────────────────────────
  scope "/api/v1", KomunBackendWeb do
    pipe_through :authenticated

    # Current user
    get   "/me", UserController, :me
    put   "/me", UserController, :update_profile
    patch "/me", UserController, :update_profile

    # Organizations
    get  "/organizations/:id", OrganizationController, :show
    get  "/organizations/:id/buildings", OrganizationController, :buildings

    # Buildings
    get    "/buildings", BuildingController, :index
    # Note: :join must be declared before :show so "join" isn't parsed as an :id.
    post   "/buildings/join", BuildingController, :join
    get    "/buildings/:id", BuildingController, :show
    get    "/buildings/:id/members", BuildingController, :members
    get    "/buildings/:id/lots", BuildingController, :lots

    # Incidents
    resources "/buildings/:building_id/incidents", IncidentController, except: [:new, :edit] do
      post "/comments", IncidentCommentController, :create
      post "/confirm-ai", IncidentController, :confirm_ai_answer
      delete "/confirm-ai", IncidentController, :unconfirm_ai_answer
    end

    # Announcements
    resources "/buildings/:building_id/announcements", AnnouncementController,
      except: [:new, :edit]

    # Assembly (AG)
    resources "/buildings/:building_id/assemblies", AssemblyController,
      except: [:new, :edit] do
      resources "/agenda_items", AgendaItemController, only: [:index, :create, :update, :delete]
    end

    # Votes (standalone, per building)
    get  "/buildings/:building_id/votes",         VoteController, :index
    post "/buildings/:building_id/votes",         VoteController, :create
    get  "/buildings/:building_id/votes/:id",     VoteController, :show
    post "/buildings/:building_id/votes/:id/respond", VoteController, :respond
    put  "/buildings/:building_id/votes/:id/close",   VoteController, :close

    # Documents
    get "/buildings/:building_id/documents/mandatory", DocumentController, :mandatory
    post   "/buildings/:building_id/documents/:id/archive", DocumentController, :archive
    delete "/buildings/:building_id/documents/:id/archive", DocumentController, :unarchive
    resources "/buildings/:building_id/documents", DocumentController,
      except: [:new, :edit]

    # Channels (threads per residence)
    resources "/buildings/:building_id/channels", ChannelController,
      except: [:new, :edit, :show]

    # AI assistant (chatbot)
    get  "/buildings/:building_id/assistant/history", AssistantController, :history
    get  "/buildings/:building_id/assistant/status",  AssistantController, :status
    post "/buildings/:building_id/assistant/ask",     AssistantController, :ask

    # Push notification device registration
    post "/devices/register", DeviceController, :register
    delete "/devices/:token", DeviceController, :unregister

    # Invites — création et utilisation
    post "/buildings/:building_id/invites", InviteController, :create
    post "/invites/:token/join", InviteController, :join

  end

  # ── Dev login (guarded by ALLOW_DEV_LOGIN env var at runtime) ────────────
  scope "/api/v1", KomunBackendWeb do
    pipe_through :api
    post "/auth/dev-login", AuthController, :dev_login
  end

  # ── Admin routes (super_admin only) ───────────────────────────────────────
  scope "/api/v1/admin", KomunBackendWeb do
    pipe_through [:authenticated, :require_super_admin]

    get    "/users",                           AdminController, :list_users
    get    "/users/:id",                       AdminController, :show_user
    put    "/users/:id/role",                  AdminController, :update_user_role
    delete "/users/:id",                       AdminController, :delete_user
    delete "/users/:id/onboarding",            AdminController, :reset_onboarding
    get    "/buildings",                       AdminController, :list_buildings
    post   "/buildings",                       AdminController, :create_building
    post   "/buildings/:id/members",           AdminController, :add_member
    delete "/buildings/:id/members/:user_id",  AdminController, :remove_member
  end
end
