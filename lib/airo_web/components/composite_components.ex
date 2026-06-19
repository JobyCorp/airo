defmodule AiroWeb.CompositeComponents do
  @moduledoc """
  Generic, multi-primitive composites for this app.

  Composites live one layer above core wrappers: they bundle a small set
  of `JobyKit.CoreComponents` primitives into a higher-level pattern that
  appears more than once across the app. Examples: empty states, page
  headers with breadcrumbs, callouts, hero blocks.

  Every composite follows the JobyKit wrapper contract:

    1. Declare every prop with `attr` (use `values:` for variant enums).
    2. Carry a `data-component` attribute naming the module and function on the
       root element.
    3. Accept `attr :rest, :global` for id/class/aria-*/phx-* pass-through.
    4. Internals compose `JobyKit.CoreComponents` (or other registered
       wrappers) — never raw `<button>`/`<input>`/`<textarea>`.
    5. Register the composite in `AiroWeb.DesignManifest`
       (`category: :composite`) so it surfaces on `/custom-designs` and
       in `/design.json`.

  The `empty_state/1` below ships pre-registered as a worked example.
  Use it as a template when you add your own composites: copy the
  attribute / slot / `data-component` shape, then register the new entry
  in the manifest.
  """

  use AiroWeb, :html

  alias JobyKit.CoreComponents

  @doc """
  An upstream-health pill: a colored dot plus the status word. Reads as a
  compact status indicator inside admin tables (providers, deployments).

      <.health_status status="up" />
      <.health_status status="down" />

  `status` mirrors `Airo.Health.status/1` — `up` (reachable), `down`
  (unreachable / 5xx), or `unknown` (never probed or stale).
  """
  attr :status, :string, values: ~w(up down unknown), default: "unknown"
  attr :rest, :global

  def health_status(assigns) do
    ~H"""
    <span
      data-component="AiroWeb.CompositeComponents.health_status"
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium capitalize",
        @status == "up" && "bg-success/15 text-success",
        @status == "down" && "bg-error/15 text-error",
        @status == "unknown" && "bg-base-200 text-base-content/60"
      ]}
      {@rest}
    >
      <span class={[
        "size-1.5 rounded-full",
        @status == "up" && "bg-success",
        @status == "down" && "bg-error",
        @status == "unknown" && "bg-base-content/40"
      ]} />
      {@status}
    </span>
    """
  end

  @doc """
  A compact tone-colored pill for a status, category, or tier — log levels, event
  kinds, routing classes. `tone` maps to a daisyUI semantic color.

      <.tag tone="warning">warning</.tag>
      <.tag tone="success">edge</.tag>
  """
  attr :tone, :string, values: ~w(neutral primary success warning error), default: "neutral"
  attr :rest, :global

  slot :inner_block, required: true

  def tag(assigns) do
    ~H"""
    <span
      data-component="AiroWeb.CompositeComponents.tag"
      class={[
        "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium",
        tag_tone(@tone)
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp tag_tone("primary"), do: "bg-primary/15 text-primary"
  defp tag_tone("success"), do: "bg-success/15 text-success"
  defp tag_tone("warning"), do: "bg-warning/15 text-warning"
  defp tag_tone("error"), do: "bg-error/15 text-error"
  defp tag_tone(_neutral), do: "bg-base-200 text-base-content/70"

  @doc """
  An empty-state callout: centered icon, title, supporting text, and an
  optional action slot. Use to fill an otherwise-empty container — an
  unfilled list, a search with no results, a fresh dashboard.

      <.empty_state icon="hero-inbox" title="No messages yet">
        Start a conversation with a teammate to see it here.
        <:action>
          <CoreComponents.button variant="primary">New message</CoreComponents.button>
        </:action>
      </.empty_state>
  """
  attr :icon, :string,
    default: "hero-sparkles",
    doc: "Heroicon name to display above the title."

  attr :title, :string, required: true
  attr :tone, :string, values: ~w(neutral primary), default: "neutral"
  attr :rest, :global

  slot :inner_block, doc: "Supporting copy beneath the title."
  slot :action, doc: "Optional call-to-action (typically a `<.button>`)."

  def empty_state(assigns) do
    ~H"""
    <div
      data-component="AiroWeb.CompositeComponents.empty_state"
      class={[
        "flex flex-col items-center justify-center gap-3 rounded-2xl border border-dashed px-6 py-10 text-center",
        @tone == "neutral" && "border-base-300 bg-base-100/40 text-base-content/70",
        @tone == "primary" && "border-primary/30 bg-primary/5 text-base-content"
      ]}
      {@rest}
    >
      <span class={[
        "flex size-12 items-center justify-center rounded-full",
        @tone == "neutral" && "bg-base-200 text-base-content/60",
        @tone == "primary" && "bg-primary/10 text-primary"
      ]}>
        <CoreComponents.icon name={@icon} class="size-6" />
      </span>
      <h3 class="text-base font-semibold text-base-content">{@title}</h3>
      <div :if={@inner_block != []} class="max-w-sm text-sm text-base-content/65">
        {render_slot(@inner_block)}
      </div>
      <div :if={@action != []} class="pt-1">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  The admin page header: compact breadcrumbs, a descriptor line, and optional
  right-aligned actions.

      <.page_header subtitle="Physical upstream model backends.">
        <:crumb navigate={~p"/admin/providers"}>Providers</:crumb>
        <:actions>
          <CoreComponents.button variant="primary">New provider</CoreComponents.button>
        </:actions>
      </.page_header>

  This intentionally replaces larger page-title headers inside the admin shell
  so each page has one consistent control band below the primary navigation.
  """
  attr :subtitle, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  slot :crumb, required: true do
    attr :navigate, :any
  end

  slot :actions

  def page_header(assigns) do
    assigns = assign(assigns, :crumb_count, length(assigns.crumb))

    ~H"""
    <header
      data-component="AiroWeb.CompositeComponents.page_header"
      class={[
        "flex flex-col gap-3 border-y border-base-content/10 bg-base-200/25 py-3 sm:flex-row sm:items-center sm:justify-between",
        @class
      ]}
      {@rest}
    >
      <div class="min-w-0 space-y-1">
        <nav aria-label="Breadcrumb">
          <ol class="flex min-w-0 items-center gap-2 text-sm text-base-content/60">
            <%= for {crumb, index} <- Enum.with_index(@crumb) do %>
              <li class="flex min-w-0 items-center gap-2">
                <.link
                  :if={crumb[:navigate] && index < @crumb_count - 1}
                  navigate={crumb[:navigate]}
                  class="shrink-0 transition-colors hover:text-base-content"
                >
                  {render_slot(crumb)}
                </.link>
                <span
                  :if={!crumb[:navigate] || index == @crumb_count - 1}
                  class={[
                    "truncate",
                    index == @crumb_count - 1 && "font-mono text-xs text-base-content/75"
                  ]}
                >
                  {render_slot(crumb)}
                </span>
                <span :if={index < @crumb_count - 1} aria-hidden="true" class="text-base-content/35">
                  /
                </span>
              </li>
            <% end %>
          </ol>
        </nav>
        <p :if={@subtitle} class="text-xs text-base-content/50">
          {@subtitle}
        </p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  A flat content section with one header band and one content container.

  Use this for dense admin sections where a card wrapper would create an extra
  nested `card-body` surface around already-structured content.
  """
  attr :class, :any, default: nil
  attr :body_class, :any, default: nil
  attr :rest, :global

  slot :title, required: true
  slot :actions
  slot :inner_block, required: true

  def section_panel(assigns) do
    ~H"""
    <section
      data-component="AiroWeb.CompositeComponents.section_panel"
      class={[
        "overflow-hidden rounded-lg border border-base-content/10 bg-base-200/80 shadow-[0_20px_55px_rgba(0,0,0,0.24)] ring-1 ring-white/5",
        @class
      ]}
      {@rest}
    >
      <header class="flex flex-col gap-3 border-b border-base-content/10 bg-base-300/35 px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
        <h2 class="text-base font-semibold leading-6 text-base-content">
          {render_slot(@title)}
        </h2>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
          {render_slot(@actions)}
        </div>
      </header>
      <div class={["bg-base-200/45 p-5", @body_class]}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
