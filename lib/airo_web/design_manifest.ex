defmodule AiroWeb.DesignManifest do
  @moduledoc """
  This app's component manifest. Backed by `JobyKit.Manifest`.

  Core registrations point at `JobyKit.CoreComponents`. Airo forks nothing:
  0.3 filled the gaps we used to fork for (button tones and `shape`, table
  hooks), so the two local entries here are components the kit doesn't ship
  at all — `checkbox_group` and `disclosure_table` — and neither is named
  after a kit component, so nothing shadows.

  Add a `component/3` line for every additional wrapper, composite, and
  domain component you want to surface on `/design` and
  `/custom-designs`. The JSON manifest at `/design.json` combines all
  entries.
  """

  use JobyKit.Manifest

  alias AiroWeb.CoreComponents
  alias AiroWeb.CompositeComponents
  alias AiroWeb.DesignPreviews
  alias JobyKit.CoreComponents, as: JobyKitCoreComponents

  category :core,
    label: "Core wrappers",
    description: "One wrapper per daisyUI primitive. Ship by JobyKit."

  category :composite,
    label: "Generic composites",
    description: "Multi-primitive patterns reused across domains."

  category :domain,
    label: "Domain composites",
    description: "Composites tied to a product area."

  # ---------------------------------------------------------------------- core
  # The core scaffolding. Each component carries the wrapper
  # contract (data-component, attr :rest, :global, attrs with values:
  # enums) and is lint-clean by construction.

  component CoreComponents, :checkbox_group,
    category: :core,
    daisy_basis: "checkbox",
    summary: "Visible multi-choice checkbox group for enum-array form fields.",
    preview: &DesignPreviews.checkbox_group_preview/1

  component CoreComponents, :disclosure_table,
    category: :core,
    daisy_basis: "table",
    summary: "Data table whose rows expand into an inline detail panel.",
    preview: &DesignPreviews.disclosure_table_preview/1

  component JobyKitCoreComponents, :button,
    category: :core,
    daisy_basis: "btn",
    summary:
      "Text or icon button. `variant` carries tone; `shape` squares off icon-only actions.",
    preview: &DesignPreviews.button_preview/1

  component JobyKitCoreComponents, :table,
    category: :core,
    daisy_basis: "table",
    summary: "Data table with col/action slots, an empty state, and density control.",
    preview: &DesignPreviews.table_preview/1

  component JobyKitCoreComponents, :badge,
    category: :core,
    daisy_basis: "badge",
    summary: "Status chip whose `tone` names the state rather than a colour.",
    preview: &DesignPreviews.badge_preview/1

  component JobyKitCoreComponents, :modal,
    category: :core,
    daisy_basis: "modal",
    summary: "Server-driven dialog; render it while open and wire `on_cancel` to close.",
    preview: &DesignPreviews.modal_preview/1

  component JobyKitCoreComponents, :card,
    category: :core,
    daisy_basis: "card",
    summary: "Padded content surface with eyebrow, title, and actions slots.",
    preview: &DesignPreviews.card_preview/1

  component JobyKitCoreComponents, :icon,
    category: :core,
    daisy_basis: "hero-*",
    summary: "Heroicon span. Pass `name=\"hero-x-mark\"` and an optional `class`.",
    preview: &DesignPreviews.icon_preview/1

  component JobyKitCoreComponents, :input,
    category: :core,
    daisy_basis: "input / select / textarea / checkbox",
    summary: "Form input with label and error rendering. Supports all standard input types.",
    preview: &DesignPreviews.input_preview/1

  component JobyKitCoreComponents, :flash,
    category: :core,
    daisy_basis: "alert",
    summary: "Toast-style flash notice. Use inside `flash_group/1` from your root layout.",
    preview: &DesignPreviews.flash_preview/1

  # ----------------------------------------------------------------- composite
  # `empty_state` is the worked example — a real composite that bundles
  # `<.icon>` + a heading + an optional action slot. Use it as the
  # template for your own composites: copy the attr / slot / data-component
  # shape, register the new entry here, and add a preview in
  # `design_previews.ex`. Generic composites belong in
  # `AiroWeb.CompositeComponents`; domain-specific ones in
  # their own module (e.g. `AiroWeb.ChatComponents`).

  component CompositeComponents, :empty_state,
    category: :composite,
    summary: "Centered icon + title + optional action; fills empty containers.",
    preview: &DesignPreviews.empty_state_preview/1

  component CompositeComponents, :page_header,
    category: :composite,
    summary: "Compact admin page header with breadcrumbs, descriptor copy, and actions.",
    preview: &DesignPreviews.page_header_preview/1

  component CompositeComponents, :section_panel,
    category: :composite,
    summary: "Flat admin section with a header band and one elevated content container.",
    preview: &DesignPreviews.section_panel_preview/1

  component CompositeComponents, :tag,
    category: :composite,
    summary: "Compact tone-colored status/category pill (log levels, event kinds, tiers).",
    preview: &DesignPreviews.tag_preview/1

  component CompositeComponents, :stat_tile,
    category: :composite,
    daisy_basis: "stat",
    summary: "A quiet label over a prominent value; dashboard tile where value leads.",
    preview: &DesignPreviews.stat_tile_preview/1

  component CompositeComponents, :meter,
    category: :composite,
    daisy_basis: "progress",
    summary: "Horizontal fill gauge with a mono readout; color encodes pressure.",
    preview: &DesignPreviews.meter_preview/1

  component CompositeComponents, :slider,
    category: :composite,
    daisy_basis: "range",
    summary: "Labeled range slider with a right-aligned value readout; a bounded form input.",
    preview: &DesignPreviews.slider_preview/1

  component CompositeComponents, :request_defaults,
    category: :composite,
    summary: "default_params editor for one gateway merge layer: sampler fields + JSON.",
    preview: &DesignPreviews.request_defaults_preview/1

  # -------------------------------------------------------------------- domain
  # Add domain composites here:
  #
  #   component AiroWeb.ChatComponents, :composer,
  #     category: :domain,
  #     summary: "Message composer with response-length controls."

  component CompositeComponents, :health_status,
    category: :domain,
    summary: "Upstream health pill (up/down/unknown) for admin tables.",
    preview: &DesignPreviews.health_status_preview/1

  @doc """
  Tells `JobyKit.DaisyCatalogue` which daisyUI primitives this app has
  wrapped, so the catalogue rendering flips them to `:wrapped` and links
  to the signature card on the index. The atoms must match
  `JobyKit.DaisyCatalogue` ids (`:button`, `:badge`, `:card`, …).
  """
  def daisy_overrides do
    %{
      button: %{
        wrapper: "<.button>",
        anchor: "#jobykit-component-jobykit-corecomponents-button"
      },
      badge: %{
        wrapper: "<.badge>",
        anchor: "#jobykit-component-jobykit-corecomponents-badge"
      },
      card: %{
        wrapper: "<.card>",
        anchor: "#jobykit-component-jobykit-corecomponents-card"
      },
      checkbox: %{
        wrapper: "<.checkbox_group>",
        anchor: "#jobykit-component-airoweb-corecomponents-checkbox-group"
      },
      modal: %{
        wrapper: "<.modal>",
        anchor: "#jobykit-component-jobykit-corecomponents-modal"
      },
      table: %{
        wrapper: "<.table>",
        anchor: "#jobykit-component-jobykit-corecomponents-table"
      }
    }
  end
end
