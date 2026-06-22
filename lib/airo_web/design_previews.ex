defmodule AiroWeb.DesignPreviews do
  @moduledoc """
  Per-component preview functions referenced by `AiroWeb.DesignManifest`.

  Each public function takes `assigns` (typically `%{}`) and returns a
  small HEEx rendering the component with sensible defaults. The
  manifest registers these via `preview: &AiroWeb.DesignPreviews.X_preview/1`,
  and `JobyKit.SignatureComponent` invokes them inside the per-component
  card's collapsible Preview section.

  Naming convention: every preview function ends in `_preview` so they
  don't collide with the imported component functions of the same name
  (e.g. `button` vs `button_preview`).

  The previews call the registered component modules directly so the
  rendered HTML matches what the manifest declares.
  """

  use AiroWeb, :html

  alias AiroWeb.CoreComponents
  alias AiroWeb.CompositeComponents
  alias JobyKit.CoreComponents, as: JobyKitCoreComponents

  def button_preview(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <CoreComponents.button>Secondary</CoreComponents.button>
      <CoreComponents.button variant="primary">Primary</CoreComponents.button>
      <CoreComponents.button variant="ghost">Ghost</CoreComponents.button>
      <CoreComponents.button variant="danger">Danger</CoreComponents.button>
      <CoreComponents.button size="sm">Small</CoreComponents.button>
      <CoreComponents.button size="lg">Large</CoreComponents.button>
    </div>
    """
  end

  def icon_button_preview(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <CoreComponents.icon_button icon="hero-pencil-square" label="Edit" />
      <CoreComponents.icon_button icon="hero-arrow-top-right-on-square" label="Open" />
      <CoreComponents.icon_button icon="hero-trash" label="Delete" variant="danger" />
    </div>
    """
  end

  def checkbox_group_preview(assigns) do
    assigns =
      Map.put(
        assigns,
        :form,
        Phoenix.Component.to_form(%{"capabilities" => ["chat"]}, as: :deployment)
      )

    ~H"""
    <div class="max-w-3xl">
      <CoreComponents.checkbox_group
        field={@form[:capabilities]}
        label="Capabilities"
        options={[:chat, :embeddings, :rerank, :speech]}
      />
    </div>
    """
  end

  def table_preview(assigns) do
    assigns =
      Map.put(assigns, :rows, [
        %{id: 1, name: "BAAI/bge-m3", status: "up", latency: "38 ms"},
        %{id: 2, name: "moondream:latest", status: "up", latency: "2560 ms"}
      ])

    ~H"""
    <CoreComponents.table id="preview-models" rows={@rows}>
      <:col :let={row} label="Model">
        <div class="font-medium">{row.name}</div>
      </:col>
      <:col :let={row} label="Health">{row.status}</:col>
      <:col :let={row} label="p95">{row.latency}</:col>
      <:action :let={row}>
        <CoreComponents.icon_button icon="hero-pencil-square" label={"Edit #{row.name}"} />
      </:action>
    </CoreComponents.table>
    """
  end

  def card_preview(assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <JobyKitCoreComponents.card>
        <:eyebrow>Bordered</:eyebrow>
        <:title>Default card</:title>
        Padded content surface backed by daisyUI's <code class="font-mono text-xs">card</code>.
        <:actions><CoreComponents.button>Action</CoreComponents.button></:actions>
      </JobyKitCoreComponents.card>
      <JobyKitCoreComponents.card variant="elevated">
        <:eyebrow>Elevated</:eyebrow>
        <:title>Card with shadow</:title>
        Lifts on hover via the wrapper's transition.
      </JobyKitCoreComponents.card>
    </div>
    """
  end

  def icon_preview(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-base-content/80">
      <JobyKitCoreComponents.icon name="hero-sparkles" />
      <JobyKitCoreComponents.icon name="hero-arrow-right" class="size-5" />
      <JobyKitCoreComponents.icon name="hero-bolt" class="size-7 text-primary" />
    </div>
    """
  end

  def input_preview(assigns) do
    assigns =
      assigns
      |> Map.put(:form, Phoenix.Component.to_form(%{"email" => ""}, as: :preview))

    ~H"""
    <div class="flex max-w-md flex-col gap-3">
      <JobyKitCoreComponents.input field={@form[:email]} type="email" label="Email" />
      <JobyKitCoreComponents.input
        name="bio"
        value=""
        type="textarea"
        label="Bio"
        placeholder="Tell us about yourself"
      />
    </div>
    """
  end

  def flash_preview(assigns) do
    assigns = Map.put(assigns, :preview_flash, %{"info" => "Saved.", "error" => "Try again."})

    ~H"""
    <div class="relative flex flex-col gap-2">
      <JobyKitCoreComponents.flash kind={:info} flash={@preview_flash} />
      <JobyKitCoreComponents.flash kind={:error} flash={@preview_flash} title="Heads up" />
    </div>
    """
  end

  def health_status_preview(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <CompositeComponents.health_status status="up" />
      <CompositeComponents.health_status status="down" />
      <CompositeComponents.health_status status="unknown" />
    </div>
    """
  end

  def tag_preview(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <CompositeComponents.tag tone="neutral">neutral</CompositeComponents.tag>
      <CompositeComponents.tag tone="primary">primary</CompositeComponents.tag>
      <CompositeComponents.tag tone="success">success</CompositeComponents.tag>
      <CompositeComponents.tag tone="warning">warning</CompositeComponents.tag>
      <CompositeComponents.tag tone="error">error</CompositeComponents.tag>
    </div>
    """
  end

  def stat_tile_preview(assigns) do
    ~H"""
    <div class="grid max-w-2xl gap-3 sm:grid-cols-3">
      <CompositeComponents.stat_tile label="Slots">7</CompositeComponents.stat_tile>
      <CompositeComponents.stat_tile label="Status">
        <CompositeComponents.health_status status="up" />
      </CompositeComponents.stat_tile>
      <CompositeComponents.stat_tile label="Resident">
        4
        <:sub>of 7 slots loaded</:sub>
      </CompositeComponents.stat_tile>
    </div>
    """
  end

  def meter_preview(assigns) do
    ~H"""
    <div class="max-w-md space-y-4">
      <CompositeComponents.meter label="VRAM" value={9_000} max={32_607} display="9.0 / 31.8 GB" />
      <CompositeComponents.meter label="VRAM" value={24_000} max={32_607} display="24.0 / 31.8 GB" />
      <CompositeComponents.meter label="VRAM" value={31_200} max={32_607} display="31.2 / 31.8 GB" />
      <CompositeComponents.meter label="Utilization" />
    </div>
    """
  end

  def empty_state_preview(assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <CompositeComponents.empty_state icon="hero-inbox" title="No messages yet">
        Start a conversation with a teammate to see it here.
        <:action>
          <CoreComponents.button variant="primary">New message</CoreComponents.button>
        </:action>
      </CompositeComponents.empty_state>
      <CompositeComponents.empty_state
        icon="hero-sparkles"
        title="Set up your workspace"
        tone="primary"
      >
        Connect your first integration to populate this dashboard.
      </CompositeComponents.empty_state>
    </div>
    """
  end

  def page_header_preview(assigns) do
    ~H"""
    <CompositeComponents.page_header subtitle="Physical upstream model backends.">
      <:crumb navigate="/admin/providers">Providers</:crumb>
      <:actions>
        <CoreComponents.button variant="primary" size="sm">New provider</CoreComponents.button>
      </:actions>
    </CompositeComponents.page_header>
    """
  end

  def section_panel_preview(assigns) do
    ~H"""
    <CompositeComponents.section_panel>
      <:title>Deployment copies</:title>
      <div class="grid gap-3 sm:grid-cols-3">
        <div class="rounded-md border border-base-content/10 bg-base-100/65 p-3 shadow-sm ring-1 ring-white/5">
          <div class="text-xs uppercase tracking-wide text-base-content/50">Provider</div>
          <div class="mt-1 font-semibold text-base-content">Ollama</div>
        </div>
        <div class="rounded-md border border-base-content/10 bg-base-100/65 p-3 shadow-sm ring-1 ring-white/5">
          <div class="text-xs uppercase tracking-wide text-base-content/50">Health</div>
          <div class="mt-1 font-semibold text-success">up</div>
        </div>
        <div class="rounded-md border border-base-content/10 bg-base-100/65 p-3 shadow-sm ring-1 ring-white/5">
          <div class="text-xs uppercase tracking-wide text-base-content/50">p95</div>
          <div class="mt-1 font-mono text-base-content">38 ms</div>
        </div>
      </div>
    </CompositeComponents.section_panel>
    """
  end
end
