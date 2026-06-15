defmodule AiroWeb.HomeLive do
  @moduledoc """
  Placeholder landing page. Airo is a backend gateway; the real admin UI
  arrives in sprint S6. Until then this is a simple "coming soon" page.
  """

  use AiroWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Airo")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="home">
      <main class="mx-auto flex min-h-[60vh] max-w-2xl flex-col items-center justify-center px-6 text-center">
        <p class="text-xs font-semibold uppercase tracking-[0.2em] text-base-content/50">
          airo
        </p>
        <h1 class="mt-3 text-4xl font-semibold leading-tight">Coming soon</h1>
        <p class="mt-3 text-base text-base-content/70">
          The Airo gateway is under construction.
        </p>
      </main>
    </Layouts.app>
    """
  end
end
