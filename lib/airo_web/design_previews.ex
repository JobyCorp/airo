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

  The previews call `JobyKit.CoreComponents` directly via the
  `CoreComponents` alias so the rendered HTML matches what the manifest
  declares — no dependency on the host's `<App>Web.CoreComponents`
  resolution.
  """

  use AiroWeb, :html

  alias JobyKit.CoreComponents
  alias AiroWeb.CompositeComponents

  def button_preview(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <CoreComponents.button>Default</CoreComponents.button>
      <CoreComponents.button variant="primary">Primary</CoreComponents.button>
      <CoreComponents.button size="sm">Small</CoreComponents.button>
      <CoreComponents.button size="lg">Large</CoreComponents.button>
    </div>
    """
  end

  def card_preview(assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <CoreComponents.card>
        <:eyebrow>Bordered</:eyebrow>
        <:title>Default card</:title>
        Padded content surface backed by daisyUI's <code class="font-mono text-xs">card</code>.
        <:actions><CoreComponents.button>Action</CoreComponents.button></:actions>
      </CoreComponents.card>
      <CoreComponents.card variant="elevated">
        <:eyebrow>Elevated</:eyebrow>
        <:title>Card with shadow</:title>
        Lifts on hover via the wrapper's transition.
      </CoreComponents.card>
    </div>
    """
  end

  def icon_preview(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-base-content/80">
      <CoreComponents.icon name="hero-sparkles" />
      <CoreComponents.icon name="hero-arrow-right" class="size-5" />
      <CoreComponents.icon name="hero-bolt" class="size-7 text-primary" />
    </div>
    """
  end

  def input_preview(assigns) do
    assigns =
      assigns
      |> Map.put(:form, Phoenix.Component.to_form(%{"email" => ""}, as: :preview))

    ~H"""
    <div class="flex max-w-md flex-col gap-3">
      <CoreComponents.input field={@form[:email]} type="email" label="Email" />
      <CoreComponents.input
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
      <CoreComponents.flash kind={:info} flash={@preview_flash} />
      <CoreComponents.flash kind={:error} flash={@preview_flash} title="Heads up" />
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
end
