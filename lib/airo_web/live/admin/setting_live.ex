defmodule AiroWeb.Admin.SettingLive do
  @moduledoc """
  Site settings (S24) — one singleton row, edited here.

  These are operator preferences rather than deployment config: they belong in
  the database and on this page, not in `config/*.exs`, so changing one doesn't
  need a release.
  """
  use AiroWeb, :live_view

  import AiroWeb.Time, only: [format_at: 1]

  alias Airo.Config
  alias Airo.Config.SiteSetting
  alias AiroWeb.CompositeComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Settings") |> assign_setting(Config.site_setting())}
  end

  @impl true
  def handle_event("validate", %{"site_setting" => params}, socket) do
    changeset = Config.change_site_setting(socket.assigns.setting, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"site_setting" => params}, socket) do
    case Config.update_site_setting(params) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign_setting(setting)
         |> put_flash(:info, "Settings saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp assign_setting(socket, setting) do
    socket
    |> assign(setting: setting)
    |> assign(form: to_form(Config.change_site_setting(setting)))
    |> assign(zone_options: SiteSetting.time_zone_options())
    |> assign(sample: NaiveDateTime.utc_now())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="settings">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle="Operator preferences for this Airo instance.">
          <:crumb>Settings</:crumb>
        </CompositeComponents.page_header>

        <.form
          for={@form}
          id="settings-form"
          phx-change="validate"
          phx-submit="save"
          class="max-w-3xl space-y-6"
        >
          <.card variant="bordered">
            <:eyebrow>Display</:eyebrow>
            <:title>Time zone</:title>
            <div class="grid gap-4 sm:grid-cols-2">
              <.input
                field={@form[:time_zone]}
                type="select"
                label="Time zone"
                options={@zone_options}
              />
              <div class="self-end pb-2">
                <p class="text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-base-content/55">
                  Right now
                </p>
                <p class="mt-1 font-mono text-sm text-base-content/85">{format_at(@sample)}</p>
              </div>
            </div>
            <p class="text-xs text-base-content/55">
              Timestamps are stored in UTC and rendered here. This changes how every
              admin page displays them — usage, logs, traces, agents — and nothing about
              what is recorded.
            </p>
          </.card>

          <.card variant="bordered">
            <:eyebrow>Health</:eyebrow>
            <:title>Failure tolerance</:title>
            <div class="grid gap-4 sm:grid-cols-2">
              <.input
                field={@form[:down_after_failures]}
                type="number"
                label="Mark down after (consecutive failures)"
                min="1"
                max="20"
              />
            </div>
            <p class="text-xs text-base-content/55">
              How many failing observations in a row before a deployment counts as down.
              Health is a preference signal and the gateway already fails over per
              request, so reacting to a single failure mostly produced noise: one slow
              request or one timed-out probe would mark a working model down and
              something would reverse it seconds later. Recovery is always immediate —
              one success restores it. <span class="font-mono">1</span> restores the old behaviour.
            </p>
          </.card>

          <div class="flex gap-2">
            <.button variant="primary">Save settings</.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
