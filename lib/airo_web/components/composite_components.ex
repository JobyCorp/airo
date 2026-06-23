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

  @doc """
  A single statistic: a quiet uppercase label over a prominent value, on a
  bordered surface. The value is the body slot, so it can hold a number, a
  formatted string, or another wrapper (a status pill). An optional `:sub`
  slot carries a unit or one-word qualifier.

      <.stat_tile label="Slots">7</.stat_tile>
      <.stat_tile label="Status"><.health_status status="up" /></.stat_tile>

  Use for dashboard tiles where the eyebrow + value already say everything —
  the value leads; no explanatory sentence beneath.
  """
  attr :class, :any, default: nil
  attr :label, :string, required: true
  attr :rest, :global

  slot :inner_block, required: true
  slot :sub, doc: "Optional unit or qualifier shown under the value."

  def stat_tile(assigns) do
    ~H"""
    <div
      data-component="AiroWeb.CompositeComponents.stat_tile"
      class={[
        "rounded-box border border-base-300 bg-base-100 px-4 py-3.5",
        @class
      ]}
      {@rest}
    >
      <p class="text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-base-content/55">
        {@label}
      </p>
      <div class="mt-1.5 text-2xl font-semibold leading-tight tabular-nums text-base-content">
        {render_slot(@inner_block)}
      </div>
      <p :if={@sub != []} class="mt-1 text-xs text-base-content/55">
        {render_slot(@sub)}
      </p>
    </div>
    """
  end

  @doc """
  A horizontal fill gauge for a "how full" quantity — VRAM, utilization, a
  budget. The label and a right-aligned monospaced readout sit above the bar;
  the fill width tracks `value/max` and its color encodes pressure: brand
  below 70%, warning at 70%+, error at 90%+.

      <.meter label="VRAM" value={2547} max={32607} display="2.5 / 31.8 GB" />

  Pass `display` for the readout text (with units); otherwise the percentage
  is shown. With no `value`/`max` the bar reads empty and the readout is "—".
  """
  attr :class, :any, default: nil
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :max, :any, default: nil
  attr :display, :string, default: nil
  attr :rest, :global

  def meter(assigns) do
    fraction = meter_fraction(assigns.value, assigns.max)

    assigns =
      assign(assigns,
        fraction: fraction,
        pct: if(fraction, do: round(fraction * 100), else: 0),
        fill_tone: meter_tone(fraction)
      )

    ~H"""
    <div
      data-component="AiroWeb.CompositeComponents.meter"
      class={["space-y-1.5", @class]}
      {@rest}
    >
      <div class="flex items-baseline justify-between gap-3">
        <span class="text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-base-content/55">
          {@label}
        </span>
        <span class="font-mono text-sm tabular-nums text-base-content/85">
          {@display || if(@fraction, do: "#{@pct}%", else: "—")}
        </span>
      </div>
      <div
        class="h-2 w-full overflow-hidden rounded-full bg-base-300"
        role="progressbar"
        aria-valuenow={@pct}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-label={@label}
      >
        <div
          class={["h-full rounded-full transition-[width] duration-500", @fill_tone]}
          style={"width: #{@pct}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  defp meter_fraction(value, max) when is_number(value) and is_number(max) and max > 0 do
    value |> Kernel./(max) |> max(0.0) |> min(1.0)
  end

  defp meter_fraction(_value, _max), do: nil

  defp meter_tone(f) when is_number(f) and f >= 0.9, do: "bg-error"
  defp meter_tone(f) when is_number(f) and f >= 0.7, do: "bg-warning"
  defp meter_tone(f) when is_number(f), do: "bg-primary"
  defp meter_tone(_f), do: "bg-base-content/20"

  @doc """
  A centered modal dialog (daisyUI `modal`). Server-driven: render it only while
  open (or pass `show`), wire `on_cancel` to the event that closes it. Backdrop
  click and Escape both fire `on_cancel`.

      <.modal :if={@editing} id="config" show on_cancel="cancel">
        <:title>Configure model</:title>
        <.form ...>…</.form>
        <:actions><.button variant="primary">Save</.button></:actions>
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, :string, default: nil, doc: "phx event fired on backdrop/Escape close."
  attr :rest, :global

  slot :title
  slot :actions
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      data-component="AiroWeb.CompositeComponents.modal"
      class={["modal", @show && "modal-open"]}
      phx-window-keydown={@on_cancel}
      phx-key="Escape"
      {@rest}
    >
      <div class="modal-box border border-base-300 bg-base-100" role="dialog" aria-modal="true">
        <h3
          :if={@title != []}
          class="text-lg font-semibold leading-tight text-base-content"
        >
          {render_slot(@title)}
        </h3>
        <div class="mt-3 text-sm text-base-content/80">
          {render_slot(@inner_block)}
        </div>
        <div :if={@actions != []} class="modal-action">
          {render_slot(@actions)}
        </div>
      </div>
      <button
        :if={@on_cancel}
        type="button"
        class="modal-backdrop"
        phx-click={@on_cancel}
        aria-label="Close"
      >
        close
      </button>
    </div>
    """
  end
end
