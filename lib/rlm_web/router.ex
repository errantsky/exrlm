defmodule RLMWeb.Router do
  use RLMWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RLMWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers,
         %{"content-security-policy" => "default-src 'self'; connect-src 'self' ws: wss:"}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RLMWeb do
    pipe_through :browser

    live "/", RunListLive, :index
    live "/runs/:run_id", RunDetailLive, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", RLMWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and trace debug API in development
  if Application.compile_env(:rlm, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RLMWeb.Telemetry
    end

    scope "/api/debug", RLMWeb do
      pipe_through :api

      get "/traces", TraceDebugController, :index
      get "/traces/:run_id", TraceDebugController, :show
    end
  end
end
