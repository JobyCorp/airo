defmodule AiroWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such as controllers,
  components, channels, and so on. JobyKit-flavored: imports
  `JobyKit.CoreComponents` so `<.button>`, `<.input>`, `<.icon>`, etc.
  resolve to the kit-shipped wrappers.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt sw.js)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: AiroWeb.Layouts]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML

      # JobyKit-shipped wrappers, all of them — nothing is forked. 0.3 filled
      # the gaps we used to fork for: `variant="danger"`/`"ghost"` on <.button>,
      # `shape` for icon-only buttons (was our own <.icon_button>), and the
      # <.table> hooks. Keep it that way: a fork stops receiving kit fixes and
      # `mix joby_kit.lint` will say so (`:forked_wrapper`).
      import JobyKit.CoreComponents

      # Airo-only wrappers, filling what the kit doesn't ship. Deliberately not
      # named after kit components, so nothing shadows.
      import AiroWeb.CoreComponents, only: [checkbox_group: 1, data_table: 1, disclosure_table: 1]

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias AiroWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AiroWeb.Endpoint,
        router: AiroWeb.Router,
        statics: AiroWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
