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

    # Public short-code check — used by /register to confirm a residence code
    # before asking for the email.
    #
    # `/codes/verify` est le nouveau endpoint unifié : il résout un code en
    # résidence (→ liste de bâtiments) ou en bâtiment (→ join direct) sans
    # que le frontend ait à savoir ce qu'il tient. L'ancien endpoint
    # `/buildings/verify_code` reste en place pour la rétrocompat.
    get "/codes/verify", ResidenceController, :verify_code
    get "/buildings/verify_code", BuildingController, :verify_code

    # GDPR consent log — accepts anonymous visitors (visitor_id param)
    # or authenticated users (user_id attached via optional auth).
    post "/consents", ConsentController, :create
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

    # Residences — copropriété parent des bâtiments
    get    "/residences",                                 ResidenceController, :index
    post   "/residences",                                 ResidenceController, :create
    get    "/residences/:id",                             ResidenceController, :show
    patch  "/residences/:id",                             ResidenceController, :update
    put    "/residences/:id",                             ResidenceController, :update
    delete "/residences/:id",                             ResidenceController, :delete
    post   "/residences/:id/merge",                       ResidenceController, :merge
    get    "/residences/:id/members",                     ResidenceController, :members

    # Archives (lecture seule des votes CS de l'ancienne stack Rails)
    get    "/council-votes/archived",                     ArchivedCouncilVoteController, :index
    post   "/residences/:id/buildings/:building_id/attach",
                                                          ResidenceController, :attach_building

    # Buildings
    get    "/buildings", BuildingController, :index
    # Note: :join must be declared before :show so "join" isn't parsed as an :id.
    post   "/buildings/join", BuildingController, :join
    get    "/buildings/:id", BuildingController, :show
    delete "/buildings/:id", BuildingController, :delete
    get    "/buildings/:id/members", BuildingController, :members
    get    "/buildings/:id/lots", BuildingController, :lots

    # Incidents
    resources "/buildings/:building_id/incidents", IncidentController, except: [:new, :edit] do
      post "/comments", IncidentCommentController, :create
      post "/confirm-ai", IncidentController, :confirm_ai_answer
      delete "/confirm-ai", IncidentController, :unconfirm_ai_answer
      put "/ai-answer", IncidentController, :update_ai_answer
    end

    # Doléances (réclamations collectives : rampe de parking trop anguleuse,
    # défaut de construction, etc.)
    resources "/buildings/:building_id/doleances", DoleanceController, except: [:new, :edit] do
      post   "/support",          DoleanceController, :add_support
      delete "/support",          DoleanceController, :remove_support
      post   "/generate-letter",  DoleanceController, :generate_letter
      post   "/suggest-experts",  DoleanceController, :suggest_experts
      post   "/escalate",         DoleanceController, :escalate
    end

    # Diligences (procédure encadrée pour troubles anormaux du voisinage,
    # réservée au syndic + conseil syndical — gating dans le controller).
    get   "/buildings/:building_id/diligences",        DiligenceController, :index
    post  "/buildings/:building_id/diligences",        DiligenceController, :create
    get   "/buildings/:building_id/diligences/:id",    DiligenceController, :show
    patch "/buildings/:building_id/diligences/:id",    DiligenceController, :update
    put   "/buildings/:building_id/diligences/:id",    DiligenceController, :update

    patch "/buildings/:building_id/diligences/:id/steps/:step_number",
          DiligenceController, :update_step

    post   "/buildings/:building_id/diligences/:id/files",
           DiligenceController, :upload_file
    delete "/buildings/:building_id/diligences/:id/files/:file_id",
           DiligenceController, :delete_file

    post "/buildings/:building_id/diligences/:id/generate-letter",
         DiligenceController, :generate_letter

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

    # Battles (vote à élimination en plusieurs rounds, ex. choix de
    # mobilier collectif). Création réservée CS + syndic ; tous les
    # membres du bâtiment peuvent voter.
    get  "/buildings/:building_id/battles",            BattleController, :index
    post "/buildings/:building_id/battles",            BattleController, :create
    get  "/buildings/:building_id/battles/:id",        BattleController, :show
    post "/buildings/:building_id/battles/:id/vote",   BattleController, :cast_vote
    post "/buildings/:building_id/battles/:id/advance", BattleController, :advance

    # Projects (copro devis workflow) — groups devis by project, then starts
    # a vote on the chosen devis.
    get    "/buildings/:building_id/projects",            ProjectController, :index
    post   "/buildings/:building_id/projects",            ProjectController, :create
    get    "/buildings/:building_id/projects/:id",        ProjectController, :show
    patch  "/buildings/:building_id/projects/:id",        ProjectController, :update
    put    "/buildings/:building_id/projects/:id",        ProjectController, :update
    delete "/buildings/:building_id/projects/:id",        ProjectController, :delete
    post   "/buildings/:building_id/projects/:id/start-vote", ProjectController, :start_vote

    # Devis nested under projects
    post   "/buildings/:building_id/projects/:project_id/devis",              DevisController, :create
    delete "/buildings/:building_id/projects/:project_id/devis/:id",          DevisController, :delete
    post   "/buildings/:building_id/projects/:project_id/devis/:id/analyze", DevisController, :analyze

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
    # Legacy single-thread endpoints — kept so any older client keeps working.
    get  "/buildings/:building_id/assistant/history", AssistantController, :history
    get  "/buildings/:building_id/assistant/status",  AssistantController, :status
    post "/buildings/:building_id/assistant/ask",     AssistantController, :ask

    # Multi-conversation endpoints (ChatGPT-style threads).
    get    "/buildings/:building_id/assistant/conversations",         AssistantController, :list_conversations
    post   "/buildings/:building_id/assistant/conversations",         AssistantController, :create_conversation
    get    "/buildings/:building_id/assistant/conversations/:id",     AssistantController, :show_conversation
    delete "/buildings/:building_id/assistant/conversations/:id",     AssistantController, :delete_conversation
    post   "/buildings/:building_id/assistant/conversations/:id/ask", AssistantController, :ask_in_conversation

    # Push notification device registration
    post "/devices/register", DeviceController, :register
    delete "/devices/:token", DeviceController, :unregister

    # Invites — création et utilisation
    post "/buildings/:building_id/invites", InviteController, :create
    post "/invites/:token/join", InviteController, :join

    # Local feeds (RSS) — read scope (any active member of the residence)
    get "/residences/:residence_id/rss-feeds", RssFeedController, :index
    get "/residences/:residence_id/rss-feeds/items", RssFeedController, :items

    # Floor map — cartographie des logements pour notifications voisinage.
    # Lecture : syndic + CS. Édition de l'adjacence : syndic + super_admin.
    # Le gating fin est dans le controller (cf. @read_roles / @edit_roles).
    get   "/buildings/:building_id/floor-map", FloorMapController, :show
    patch "/lots/:id/adjacency",               FloorMapController, :update_adjacency
    put   "/lots/:id/adjacency",               FloorMapController, :update_adjacency
    get   "/lots/:id/notify-preview",          FloorMapController, :notify_preview
  end

  # ── Local feeds (RSS) — admin scope ──────────────────────────────────────
  # CS members + super_admin can configure feeds for a residence.
  scope "/api/v1", KomunBackendWeb do
    pipe_through [:authenticated, KomunBackendWeb.Plugs.RequireResidenceAdmin]

    post   "/residences/:residence_id/rss-feeds",             RssFeedController, :create
    patch  "/residences/:residence_id/rss-feeds/:id",         RssFeedController, :update
    put    "/residences/:residence_id/rss-feeds/:id",         RssFeedController, :update
    delete "/residences/:residence_id/rss-feeds/:id",         RssFeedController, :delete
    post   "/residences/:residence_id/rss-feeds/:id/refresh", RssFeedController, :refresh
  end

  # ── Dev login (guarded by ALLOW_DEV_LOGIN env var at runtime) ────────────
  scope "/api/v1", KomunBackendWeb do
    pipe_through :api
    post "/auth/dev-login", AuthController, :dev_login
  end

  # ── Admin routes (super_admin only) ───────────────────────────────────────
  scope "/api/v1/admin", KomunBackendWeb do
    pipe_through [:authenticated, :require_super_admin]

    get    "/analytics",                       AdminController, :analytics
    get    "/residents/pending",               AdminController, :pending_residents
    get    "/users",                           AdminController, :list_users
    get    "/users/:id",                       AdminController, :show_user
    put    "/users/:id/role",                  AdminController, :update_user_role
    delete "/users/:id",                       AdminController, :delete_user
    post   "/users/:id/impersonate",           AdminController, :impersonate
    post   "/users/:id/magic-link",            AdminController, :generate_magic_link
    post   "/council-votes/import",            ArchivedCouncilVoteController, :import
    delete "/users/:id/onboarding",            AdminController, :reset_onboarding
    get    "/buildings",                       AdminController, :list_buildings
    post   "/buildings",                       AdminController, :create_building
    post   "/buildings/:id/members",                  AdminController, :add_member
    put    "/buildings/:id/members/:user_id/role",    AdminController, :update_member_role
    delete "/buildings/:id/members/:user_id",         AdminController, :remove_member
  end
end
