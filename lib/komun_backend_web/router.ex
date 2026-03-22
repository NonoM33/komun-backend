defmodule KomunBackendWeb.Router do
  use KomunBackendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug :accepts, ["json"]
    plug KomunBackend.Auth.Pipeline
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
  end

  # ── Authenticated routes ──────────────────────────────────────────────────
  scope "/api/v1", KomunBackendWeb do
    pipe_through :authenticated

    # Current user
    get  "/me", UserController, :me
    put  "/me", UserController, :update_profile

    # Organizations
    get  "/organizations/:id", OrganizationController, :show
    get  "/organizations/:id/buildings", OrganizationController, :buildings

    # Buildings
    get    "/buildings", BuildingController, :index
    get    "/buildings/:id", BuildingController, :show
    get    "/buildings/:id/members", BuildingController, :members
    get    "/buildings/:id/lots", BuildingController, :lots

    # Incidents
    resources "/buildings/:building_id/incidents", IncidentController, except: [:new, :edit] do
      post "/comments", IncidentCommentController, :create
    end

    # Announcements
    resources "/buildings/:building_id/announcements", AnnouncementController,
      except: [:new, :edit]

    # Assembly (AG)
    resources "/buildings/:building_id/assemblies", AssemblyController,
      except: [:new, :edit] do
      resources "/agenda_items", AgendaItemController, only: [:index, :create, :update, :delete]
      get  "/votes", VoteController, :index
      post "/votes/:vote_id/respond", VoteController, :respond
    end

    # Documents
    resources "/buildings/:building_id/documents", DocumentController,
      except: [:new, :edit]

    # Push notification device registration
    post "/devices/register", DeviceController, :register
    delete "/devices/:token", DeviceController, :unregister

  end
end
