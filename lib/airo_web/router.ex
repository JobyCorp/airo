defmodule AiroWeb.Router do
  use AiroWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AiroWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Authenticated OpenAI-compatible surface. Client-key auth halts with a 401
  # before reaching any controller.
  pipeline :gateway_api do
    plug :accepts, ["json"]
    plug AiroWeb.Plugs.ClientKeyAuth
  end

  scope "/v1", AiroWeb do
    pipe_through :gateway_api

    post "/chat/completions", ChatController, :create
    post "/embeddings", EmbeddingsController, :create
    post "/rerank", RerankController, :create
    post "/classify", ClassifyController, :create
    post "/audio/speech", AudioController, :speech
    post "/audio/transcriptions", AudioController, :transcriptions
    get "/models", ModelsController, :index
  end

  # Realtime WebSocket surface — client-key auth, no :accepts (it's a WS upgrade,
  # not a content-negotiated response).
  pipeline :realtime_api do
    plug AiroWeb.Plugs.ClientKeyAuth
  end

  scope "/v1", AiroWeb do
    pipe_through :realtime_api

    get "/realtime", RealtimeController, :connect
  end

  scope "/", AiroWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/design", DesignSystemLive, :index
    live "/custom-designs", CustomDesignsLive, :index

    live "/admin/models", Admin.ModelLive, :index
    live "/admin/models/new", Admin.ModelLive, :new
    live "/admin/models/:id", Admin.ModelLive, :show
    live "/admin/models/:id/edit", Admin.ModelLive, :edit
    live "/admin/providers", Admin.ProviderLive, :index
    live "/admin/providers/new", Admin.ProviderLive, :new
    live "/admin/providers/:id", Admin.ProviderLive, :show
    live "/admin/providers/:id/edit", Admin.ProviderLive, :edit
    live "/admin/agents", Admin.AgentLive, :index
    live "/admin/agents/:id", Admin.AgentLive, :show
    live "/admin/deployments", Admin.DeploymentLive, :index
    live "/admin/deployments/new", Admin.DeploymentLive, :new
    live "/admin/deployments/:id", Admin.DeploymentLive, :show
    live "/admin/deployments/:id/edit", Admin.DeploymentLive, :edit
    live "/admin/aliases", Admin.AliasLive, :index
    live "/admin/aliases/new", Admin.AliasLive, :new
    live "/admin/aliases/:id", Admin.AliasLive, :show
    live "/admin/aliases/:id/edit", Admin.AliasLive, :edit
    live "/admin/keys", Admin.KeyLive, :index
    live "/admin/keys/new", Admin.KeyLive, :new
    live "/admin/routing", Admin.RoutingLive, :index
    live "/admin/usage", Admin.UsageLive, :index
    live "/admin/logs", Admin.LogsLive, :index
    live "/admin/logs/:trace_id", Admin.TraceLive, :show
  end

  scope "/" do
    pipe_through :api

    get "/design.json", JobyKit.ManifestController, :show,
      private: %{joby_kit_manifest: AiroWeb.DesignManifest}

    get "/openapi", AiroWeb.OpenApiController, :show
  end

  # Interactive API reference (Swagger UI) over the /openapi document.
  scope "/" do
    pipe_through :browser

    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/openapi"
  end

  if Application.compile_env(:airo, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AiroWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
