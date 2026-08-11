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

  def data_table_preview(assigns) do
    assigns =
      Map.put(assigns, :rows, [
        %{id: 1, name: "BAAI/bge-m3", status: "up", latency: "38 ms"},
        %{id: 2, name: "moondream:latest", status: "up", latency: "2560 ms"}
      ])

    ~H"""
    <CoreComponents.data_table id="preview-data-table" rows={@rows}>
      <:col :let={row} label="Model">
        <div class="font-medium">{row.name}</div>
      </:col>
      <:col :let={row} label="Health">{row.status}</:col>
      <:col :let={row} label="p95">{row.latency}</:col>
      <:empty>No models yet.</:empty>
    </CoreComponents.data_table>
    """
  end

  def disclosure_table_preview(assigns) do
    assigns =
      Map.put(assigns, :rows, [
        %{id: 1, name: "BAAI/bge-m3", status: "up", latency: "38 ms"},
        %{id: 2, name: "moondream:latest", status: "up", latency: "2560 ms"}
      ])

    ~H"""
    <CoreComponents.disclosure_table
      id="preview-models"
      rows={@rows}
      row_id={&"preview-model-#{&1.id}"}
    >
      <:col :let={row} label="Model">
        <div class="font-medium">{row.name}</div>
      </:col>
      <:col :let={row} label="Health">{row.status}</:col>
      <:col :let={row} label="p95">{row.latency}</:col>
      <:detail :let={row}>
        Expanded detail for {row.name}.
      </:detail>
    </CoreComponents.disclosure_table>
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

  def slider_preview(assigns) do
    ~H"""
    <div class="max-w-md space-y-4">
      <CompositeComponents.slider
        name="ctx"
        value={65_536}
        min={1024}
        max={262_144}
        step={1024}
        label="Context window"
      >
        <:readout>65536 / 262144</:readout>
      </CompositeComponents.slider>
      <CompositeComponents.slider name="weight" value={40} min={0} max={100} step={5} label="Weight">
        <:readout>40%</:readout>
      </CompositeComponents.slider>
    </div>
    """
  end

  def request_defaults_preview(assigns) do
    ~H"""
    <div class="max-w-2xl">
      <CompositeComponents.request_defaults
        layer="deployment"
        prefix="preview"
        values={
          %{
            "temperature" => "0.7",
            "top_p" => "0.8",
            "presence_penalty" => "1.5",
            "frequency_penalty" => ""
          }
        }
        json={~s({\n  "max_tokens": 4096\n})}
      />
    </div>
    """
  end

  def empty_state_preview(assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <CompositeComponents.empty_state icon="hero-inbox" title="No messages yet">
        Start a conversation with a teammate to see it here.
        <:action>
          <JobyKitCoreComponents.button variant="primary">New message</JobyKitCoreComponents.button>
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
        <JobyKitCoreComponents.button variant="primary" size="sm">
          New provider
        </JobyKitCoreComponents.button>
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
