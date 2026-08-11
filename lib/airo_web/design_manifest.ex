defmodule AiroWeb.DesignManifest do
  @moduledoc """
  This app's component manifest. Backed by `JobyKit.Manifest`.

  **Registers only Airo's own components.** `/design` is the kit's page:
  since 0.3.2 it renders `JobyKit.KitManifest` directly, so registering
  kit components here does nothing except pin a snapshot of whatever
  inventory the kit had when the line was written. Airo had eight such
  entries against the fourteen the kit ships — the six it never listed
  (`eyebrow`, `flash_group`, `header`, `list`, `simple_nav`,
  `theme_toggle`) were invisible on our `/design` as though they didn't
  exist. They're gone; the kit lists itself.

  Which page an entry lands on is decided by who owns the module, not by
  the `category` below — everything here is Airo's, so all of it renders
  on `/custom-designs`. Category only groups entries within that page.
  """

  use JobyKit.Manifest

  alias AiroWeb.CoreComponents
  alias AiroWeb.CompositeComponents
  alias AiroWeb.DesignPreviews

  category :wrapper,
    label: "App wrappers",
    description: "Single primitives the kit doesn't ship, wrapped to the same contract."

  category :composite,
    label: "Generic composites",
    description: "Multi-primitive patterns reused across domains."

  category :domain,
    label: "Domain composites",
    description: "Composites tied to a product area."

  # ------------------------------------------------------------------- wrapper
  # Two primitives the kit has no equivalent for. Both carry the wrapper
  # contract (data-component, attr :rest, :global, attrs with values: enums).
  # Neither is named after a kit component, so nothing shadows `<.table>`.

  component CoreComponents, :checkbox_group,
    category: :wrapper,
    daisy_basis: "checkbox",
    summary: "Visible multi-choice checkbox group for enum-array form fields.",
    preview: &DesignPreviews.checkbox_group_preview/1

  component CoreComponents, :disclosure_table,
    category: :wrapper,
    daisy_basis: "table",
    summary: "Data table whose rows expand into an inline detail panel.",
    preview: &DesignPreviews.disclosure_table_preview/1

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
  The daisyUI primitives *Airo* wraps that the kit doesn't.

  `JobyKit.DaisyCatalogue.merged/1` merges this over
  `JobyKit.KitManifest.daisy_overrides/0`, so restating a primitive the
  kit already claims (button, badge, card, table, modal, alert, the four
  `<.input>` types, …) is pure duplication — and stale duplication the
  moment the kit's anchors change. Only list what the kit leaves
  unwrapped, or the catalogue will show it as `:available` and invite the
  next contributor to hand-roll a primitive we already have.

  These three live on `/custom-designs`, so the anchors carry that path —
  the catalogue itself renders on `/design`.
  """
  def daisy_overrides do
    %{
      range: %{wrapper: "<.slider>", anchor: custom_anchor("slider")},
      progress: %{wrapper: "<.meter>", anchor: custom_anchor("meter")},
      stat: %{wrapper: "<.stat_tile>", anchor: custom_anchor("stat_tile")}
    }
  end

  defp custom_anchor(function),
    do: "/custom-designs#jobykit-component-airoweb-compositecomponents-#{function}"
end
