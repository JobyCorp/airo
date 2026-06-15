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
  end

  scope "/", AiroWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/design", DesignSystemLive, :index
    live "/custom-designs", CustomDesignsLive, :index
  end

  scope "/" do
    pipe_through :api

    get "/design.json", JobyKit.ManifestController, :show,
      private: %{joby_kit_manifest: AiroWeb.DesignManifest}
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
