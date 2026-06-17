defmodule AiroWeb.Admin.ModelLive do
  @moduledoc "Model Shelf admin surface for model identity, deployments, and performance."
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.Model
  alias Airo.LocalModels
  alias Airo.ModelShelf
  alias AiroWeb.CompositeComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Model Shelf")
     |> assign(form: nil, editing: nil, detail: nil)
     |> assign(status_options: optionize(Model.statuses()))
     |> stream(:models, ModelShelf.list_summaries(), dom_id: &"model-#{&1.model.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: model_return_path(socket.assigns.editing))}
  end

  def handle_event("validate", %{"model" => params}, socket) do
    changeset = Config.change_model(socket.assigns.editing || %Model{}, clean(params))
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"model" => params}, socket) do
    save(socket, socket.assigns.editing, clean(params))
  end

  def handle_event("sync_deployment", %{"id" => id}, socket) do
    deployment = Config.get_deployment!(id)

    case LocalModels.sync_deployment(deployment) do
      {:ok, _deployment} ->
        {:noreply,
         socket
         |> refresh_detail()
         |> put_flash(:info, "Provider metadata synced.")}

      {:error, :unsupported} ->
        {:noreply, put_flash(socket, :error, "This provider does not expose local metadata.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Metadata sync failed: #{inspect(reason)}")}
    end
  end

  defp save(socket, nil, params) do
    case Config.create_model(params) do
      {:ok, model} ->
        {:noreply,
         socket
         |> put_flash(:info, "Model created.")
         |> push_navigate(to: ~p"/admin/models/#{model.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, model, params) do
    case Config.update_model(model, params) do
      {:ok, model} ->
        {:noreply,
         socket
         |> put_flash(:info, "Model updated.")
         |> push_navigate(to: ~p"/admin/models/#{model.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Model Shelf", detail: nil, form: nil, editing: nil)
    |> stream(:models, ModelShelf.list_summaries(), reset: true)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    socket
    |> assign(detail: ModelShelf.get_detail!(id), form: nil, editing: nil)
    |> assign(page_title: "Model Shelf")
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New model", detail: nil, editing: nil)
    |> assign(form: to_form(Config.change_model(%Model{})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    model = Config.get_model!(id)

    socket
    |> assign(page_title: "Edit model", detail: nil, editing: model)
    |> assign(form: to_form(Config.change_model(model)))
  end

  defp refresh_detail(%{assigns: %{detail: %{model: model}}} = socket) do
    assign(socket, detail: ModelShelf.get_detail!(model.id), form: nil, editing: nil)
  end

  defp refresh_detail(socket), do: socket

  defp model_return_path(%Model{id: id}), do: ~p"/admin/models/#{id}"
  defp model_return_path(_model), do: ~p"/admin/models"

  defp clean(params), do: for({k, v} <- params, v != "", into: %{}, do: {k, v})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="models">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle={
          model_header_subtitle(@live_action, @detail, @editing)
        }>
          <:crumb navigate={~p"/admin/models"}>Models</:crumb>
          <:crumb :if={@live_action == :show}>{@detail.model.family || "unclassified"}</:crumb>
          <:crumb :if={@live_action == :new}>New model</:crumb>
          <:crumb :if={@live_action == :edit}>{@editing.display_name}</:crumb>
          <:actions :if={@live_action == :index}>
            <.button navigate={~p"/admin/models/new"} variant="primary">New model</.button>
          </:actions>
          <:actions :if={@live_action == :show}>
            <.button size="sm" navigate={~p"/admin/models/#{@detail.model.id}/edit"} variant="primary">
              Edit metadata
            </.button>
          </:actions>
          <:actions :if={@live_action in [:new, :edit]}>
            <.button size="sm" navigate={model_return_path(@editing)}>Back</.button>
          </:actions>
        </CompositeComponents.page_header>

        <%= cond do %>
          <% @form -> %>
            <.model_form form={@form} editing={@editing} status_options={@status_options} />
          <% @detail -> %>
            <.detail detail={@detail} />
          <% true -> %>
            <.shelf models={@streams.models} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :editing, :any, required: true
  attr :status_options, :list, required: true

  defp model_form(assigns) do
    ~H"""
    <.card variant="bordered">
      <:title>Model metadata</:title>
      <.form
        for={@form}
        id="model-form"
        phx-change="validate"
        phx-submit="save"
        class="grid gap-4 md:grid-cols-2"
      >
        <.input field={@form[:display_name]} label="Display name" />
        <.input field={@form[:upstream_model_id]} label="Upstream model id" />
        <.input field={@form[:family]} label="Family" />
        <.input field={@form[:version]} label="Version" />
        <.input field={@form[:revision]} label="Revision" />
        <.input field={@form[:quantization]} label="Quantization" />
        <.input field={@form[:size]} label="Size" />
        <.input
          field={@form[:status]}
          type="select"
          label="Lifecycle status"
          options={@status_options}
        />
        <.input field={@form[:notes]} type="textarea" label="Notes" class="md:col-span-2" />
        <div class="flex gap-2 md:col-span-2">
          <.button variant="primary">Save</.button>
          <.button type="button" phx-click="cancel">Cancel</.button>
        </div>
      </.form>
    </.card>
    """
  end

  attr :models, :any, required: true

  defp shelf(assigns) do
    ~H"""
    <.table
      id="models"
      rows={@models}
      row_click={fn {_id, summary} -> JS.navigate(~p"/admin/models/#{summary.model.id}") end}
    >
      <:col :let={{_id, summary}} label="Model">
        <div class="font-medium">{summary.model.display_name}</div>
        <div class="font-mono text-xs text-base-content/60">{summary.model.upstream_model_id}</div>
      </:col>
      <:col :let={{_id, summary}} label="Status">{summary.model.status}</:col>
      <:col :let={{_id, summary}} label="Capabilities">
        {join_values(summary.capabilities)}
      </:col>
      <:col :let={{_id, summary}} label="Class">{join_values(summary.classes)}</:col>
      <:col :let={{_id, summary}} label="Deployments">
        {summary.enabled_deployment_count}/{summary.deployment_count}
      </:col>
      <:col :let={{_id, summary}} label="Health">
        <CompositeComponents.health_status status={to_string(summary.health)} />
      </:col>
      <:col :let={{_id, summary}} label="Requests">{summary.requests}</:col>
      <:col :let={{_id, summary}} label="Errors">{summary.error_rate}</:col>
      <:col :let={{_id, summary}} label="p95">{latency(summary.p95_latency_ms)}</:col>
      <:col :let={{_id, summary}} label="Fallbacks">{summary.fallback_rate}</:col>
      <:col :let={{_id, summary}} label="Cost">{summary.cost}</:col>
      <:action :let={{_id, summary}}>
        <.icon_button
          icon="hero-pencil-square"
          label={"Edit #{summary.model.display_name}"}
          navigate={~p"/admin/models/#{summary.model.id}/edit"}
        />
      </:action>
    </.table>
    """
  end

  attr :detail, :map, required: true

  defp detail(assigns) do
    ~H"""
    <div class="space-y-5">
      <div class="grid gap-4 md:grid-cols-3 xl:grid-cols-6">
        <.card variant="bordered" class="border-l-4 border-l-info">
          <:eyebrow>Deployments</:eyebrow>
          <:title>
            {@detail.summary.enabled_deployment_count}/{@detail.summary.deployment_count}
          </:title>
          Enabled copies.
        </.card>
        <.card variant="bordered" class="border-l-4 border-l-success">
          <:eyebrow>Health</:eyebrow>
          <:title>{@detail.summary.health}</:title>
          Aggregate posture.
        </.card>
        <.card variant="bordered" class="border-l-4 border-l-base-content/25">
          <:eyebrow>Requests</:eyebrow>
          <:title>{@detail.summary.requests}</:title>
          Recorded calls.
        </.card>
        <.card variant="bordered" class="border-l-4 border-l-error">
          <:eyebrow>Error rate</:eyebrow>
          <:title>{@detail.summary.error_rate}</:title>
          From usage rows.
        </.card>
        <.card variant="bordered" class="border-l-4 border-l-warning">
          <:eyebrow>p95 latency</:eyebrow>
          <:title>{latency(@detail.summary.p95_latency_ms)}</:title>
          Served calls.
        </.card>
        <.card variant="bordered" class="border-l-4 border-l-base-content/25">
          <:eyebrow>Fallbacks</:eyebrow>
          <:title>{@detail.summary.fallback_rate}</:title>
          Later candidates.
        </.card>
      </div>

      <CompositeComponents.section_panel>
        <:title>
          <span class="font-mono text-base break-all md:text-lg">{@detail.model.display_name}</span>
        </:title>
        <dl class="grid gap-x-10 gap-y-5 text-sm md:grid-cols-2 xl:grid-cols-4">
          <div :for={field <- model_identity_fields(@detail)} class="min-w-0">
            <dt class="text-xs uppercase tracking-wide text-base-content/50">{field.label}</dt>
            <dd class={[
              "mt-1 break-words text-base-content/90",
              field.mono && "font-mono",
              field.compact && "text-xs"
            ]}>
              {field.value}
            </dd>
          </div>
        </dl>
        <p
          :if={@detail.model.notes}
          class="mt-5 border-t border-base-content/10 pt-4 text-sm text-base-content/70"
        >
          {@detail.model.notes}
        </p>
      </CompositeComponents.section_panel>

      <CompositeComponents.section_panel
        :if={@detail.leading_deployment}
        class="border-l-4 border-l-warning"
      >
        <:title>Deployment guidance</:title>
        <div class="grid gap-4 text-sm md:grid-cols-[1.1fr_1fr_1.5fr_0.7fr_1.5fr]">
          <div>
            <span class="text-base-content/60">Recommendation</span>
            <br />
            <span class={[
              "inline-flex rounded border px-2 py-1 font-semibold",
              recommendation_class(@detail.leading_deployment.recommendation)
            ]}>
              {@detail.leading_deployment.recommendation}
            </span>
          </div>
          <div>
            <span class="text-base-content/60">Provider</span>
            <br />{@detail.leading_deployment.provider && @detail.leading_deployment.provider.name}
          </div>
          <div>
            <span class="text-base-content/60">Model id</span>
            <br /><span class="break-all">{@detail.leading_deployment.deployment.model_name}</span>
          </div>
          <div>
            <span class="text-base-content/60">Score</span>
            <br />
            <span class="font-mono text-base text-base-content">
              {@detail.leading_deployment.guidance_score}/100
            </span>
          </div>
          <div>
            <span class="text-base-content/60">Reason</span>
            <br />{@detail.leading_deployment.guidance_reason}
          </div>
        </div>
      </CompositeComponents.section_panel>

      <CompositeComponents.section_panel>
        <:title>Version performance</:title>
        <div id="model-versions" class="space-y-3">
          <div
            :if={@detail.version_summaries == []}
            class="rounded-md border border-dashed border-base-content/15 bg-base-100/45 px-4 py-5 text-sm text-base-content/60"
          >
            No version samples yet.
          </div>
          <div
            :for={row <- @detail.version_summaries}
            class="grid gap-4 rounded-md border border-base-content/10 bg-base-100/65 p-4 shadow-sm ring-1 ring-white/5 xl:grid-cols-[1.1fr_2fr]"
          >
            <div class="min-w-0">
              <div class="font-mono text-xs uppercase tracking-[0.2em] text-base-content/50">
                Version
              </div>
              <div class="mt-1 break-all font-mono text-base font-semibold text-base-content">
                {row.version}
              </div>
              <div class="mt-2 text-sm text-base-content/60">
                Revision <span class="font-mono">{row.revision || "—"}</span>
              </div>
            </div>
            <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">Requests</div>
                <div class="mt-1 font-mono text-base text-base-content">{row.requests}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">Errors</div>
                <div class="mt-1 font-mono text-base text-base-content">{row.error_rate}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">p50</div>
                <div class="mt-1 font-mono text-base text-base-content">
                  {latency(row.p50_latency_ms)}
                </div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">p95</div>
                <div class="mt-1 font-mono text-base text-base-content">
                  {latency(row.p95_latency_ms)}
                </div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">Fallbacks</div>
                <div class="mt-1 font-mono text-base text-base-content">{row.fallback_rate}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">Cost</div>
                <div class="mt-1 font-mono text-base text-base-content">{row.cost}</div>
              </div>
              <div class="sm:col-span-2">
                <div class="text-xs uppercase tracking-wide text-base-content/50">First seen</div>
                <div class="mt-1 font-mono text-sm text-base-content/80">{row.first_seen}</div>
              </div>
              <div class="sm:col-span-2">
                <div class="text-xs uppercase tracking-wide text-base-content/50">Last seen</div>
                <div class="mt-1 font-mono text-sm text-base-content/80">{row.last_seen}</div>
              </div>
            </div>
          </div>
        </div>
      </CompositeComponents.section_panel>

      <CompositeComponents.section_panel>
        <:title>Deployment copies</:title>
        <div id="model-deployments" class="space-y-3">
          <div
            :if={@detail.deployment_summaries == []}
            class="rounded-md border border-dashed border-base-content/15 bg-base-100/45 px-4 py-5 text-sm text-base-content/60"
          >
            No deployment copies are linked to this model yet.
          </div>
          <div
            :for={row <- @detail.deployment_summaries}
            class="rounded-md border border-base-content/10 bg-base-100/65 p-4 shadow-sm ring-1 ring-white/5"
          >
            <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-semibold text-base-content">
                    {row.provider && row.provider.name}
                  </span>
                  <CompositeComponents.health_status status={to_string(row.health)} />
                  <span class={[
                    "inline-flex rounded border px-2 py-0.5 text-xs font-semibold",
                    recommendation_class(row.recommendation)
                  ]}>
                    {row.recommendation}
                  </span>
                </div>
                <div class="mt-2 break-all font-mono text-sm text-base-content/75">
                  {row.deployment.model_name}
                </div>
              </div>
              <div class="grid shrink-0 grid-cols-3 gap-3 text-sm lg:min-w-96">
                <div>
                  <div class="text-xs uppercase tracking-wide text-base-content/50">Score</div>
                  <div class="mt-1 font-mono text-base text-base-content">
                    {row.guidance_score}/100
                  </div>
                </div>
                <div>
                  <div class="text-xs uppercase tracking-wide text-base-content/50">Requests</div>
                  <div class="mt-1 font-mono text-base text-base-content">{row.requests}</div>
                </div>
                <div>
                  <div class="text-xs uppercase tracking-wide text-base-content/50">p95</div>
                  <div class="mt-1 font-mono text-base text-base-content">
                    {latency(row.p95_latency_ms)}
                  </div>
                </div>
              </div>
            </div>

            <div class="mt-4 grid gap-3 text-sm sm:grid-cols-2 xl:grid-cols-4">
              <div class="xl:col-span-2">
                <div class="text-xs uppercase tracking-wide text-base-content/50">Reason</div>
                <div class="mt-1 text-base-content/80">{row.guidance_reason}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">Enabled</div>
                <div class="mt-1 font-mono text-base-content/80">{row.deployment.enabled}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">Capabilities</div>
                <div class="mt-1 text-base-content/80">
                  {join_values(row.deployment.capabilities)}
                </div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">Errors</div>
                <div class="mt-1 font-mono text-base-content/80">{row.error_rate}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">p50</div>
                <div class="mt-1 font-mono text-base-content/80">
                  {latency(row.p50_latency_ms)}
                </div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">Fallbacks</div>
                <div class="mt-1 font-mono text-base-content/80">{row.fallback_rate}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/50">Synced</div>
                <div class="mt-1 font-mono text-base-content/80">
                  {metadata_value(row.deployment, "synced_at")}
                </div>
              </div>
            </div>

            <div :if={:inspect_model in row.local_capabilities} class="mt-4 flex justify-end">
              <.button
                size="sm"
                phx-click="sync_deployment"
                phx-value-id={row.deployment.id}
              >
                Sync
              </.button>
            </div>
          </div>
        </div>
      </CompositeComponents.section_panel>

      <CompositeComponents.section_panel>
        <:title>Provider metadata</:title>
        <div id="provider-metadata" class="space-y-3">
          <div
            :if={@detail.deployment_summaries == []}
            class="rounded-md border border-dashed border-base-content/15 bg-base-100/45 px-4 py-5 text-sm text-base-content/60"
          >
            No provider metadata has been synced yet.
          </div>
          <div
            :for={row <- @detail.deployment_summaries}
            class="rounded-md border border-base-content/10 bg-base-100/65 p-4 shadow-sm ring-1 ring-white/5"
          >
            <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <div class="font-semibold text-base-content">
                  {row.provider && row.provider.name}
                </div>
                <div class="mt-2 flex flex-wrap gap-2 font-mono text-xs text-base-content/65">
                  <span
                    :if={metadata_reported?(row.deployment, "type")}
                    class="rounded-full border border-base-content/10 bg-base-300/40 px-2 py-1"
                  >
                    {metadata_value(row.deployment, "type")}
                  </span>
                  <span
                    :if={metadata_reported?(row.deployment, "backend")}
                    class="rounded-full border border-base-content/10 bg-base-300/40 px-2 py-1"
                  >
                    {metadata_value(row.deployment, "backend")}
                  </span>
                  <span
                    :if={
                      !metadata_reported?(row.deployment, "type") &&
                        !metadata_reported?(row.deployment, "backend")
                    }
                    class="text-base-content/45"
                  >
                    No runtime type reported
                  </span>
                </div>
              </div>
              <span class={[
                "inline-flex w-fit items-center rounded-full border px-2.5 py-1 text-xs font-medium",
                running_label(row.deployment) == "yes" &&
                  "border-success/30 bg-success/10 text-success",
                running_label(row.deployment) == "no" &&
                  "border-base-content/10 bg-base-300/35 text-base-content/65",
                running_label(row.deployment) == "—" &&
                  "border-base-content/10 bg-base-300/20 text-base-content/45"
              ]}>
                Running {running_label(row.deployment)}
              </span>
            </div>

            <div class="mt-5 grid gap-4 xl:grid-cols-[minmax(0,1fr)_22rem]">
              <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
                <div
                  :for={{label, value} <- provider_metadata_present_fields(row.deployment)}
                  class="rounded-md border border-base-content/10 bg-base-300/30 p-3 shadow-sm ring-1 ring-white/5"
                >
                  <div class="text-xs uppercase tracking-wide text-base-content/50">{label}</div>
                  <div class="mt-1 break-all font-mono text-base-content/85">{value}</div>
                </div>

                <div
                  :if={provider_metadata_present_fields(row.deployment) == []}
                  class="rounded-md border border-dashed border-base-content/15 bg-base-300/25 p-3 text-sm text-base-content/55"
                >
                  This provider has not reported detailed metadata yet.
                </div>
              </div>

              <div
                :if={provider_metadata_missing_labels(row.deployment) != []}
                class="rounded-md border border-dashed border-base-content/10 bg-base-300/20 p-3"
              >
                <div class="text-xs uppercase tracking-wide text-base-content/45">Not reported</div>
                <div class="mt-3 flex flex-wrap gap-2">
                  <span
                    :for={label <- provider_metadata_missing_labels(row.deployment)}
                    class="rounded-full border border-base-content/10 bg-base-100/30 px-2 py-1 text-xs text-base-content/55"
                  >
                    {label}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </CompositeComponents.section_panel>

      <CompositeComponents.section_panel body_class="p-4">
        <:title>Routing participation</:title>
        <.table id="model-aliases" rows={@detail.aliases}>
          <:col :let={candidate} label="Alias">{candidate.alias.name}</:col>
          <:col :let={candidate} label="Capability">{candidate.alias.capability}</:col>
          <:col :let={candidate} label="Strategy">{candidate.alias.strategy}</:col>
          <:col :let={candidate} label="Provider">
            {candidate.deployment.provider && candidate.deployment.provider.name}
          </:col>
          <:col :let={candidate} label="Weight">{candidate.weight}</:col>
          <:col :let={candidate} label="Priority">{candidate.priority}</:col>
        </.table>
      </CompositeComponents.section_panel>

      <CompositeComponents.section_panel body_class="p-4">
        <:title>Recent health transitions</:title>
        <.table id="model-health-events" rows={@detail.health_events}>
          <:col :let={event} label="When">{event.inserted_at}</:col>
          <:col :let={event} label="Provider">{event.provider && event.provider.name}</:col>
          <:col :let={event} label="Status">
            <CompositeComponents.health_status status={to_string(event.status)} />
          </:col>
          <:col :let={event} label="Source">{event.source}</:col>
          <:col :let={event} label="Latency">{latency(event.latency_ms)}</:col>
          <:col :let={event} label="Reason">{event.reason || "—"}</:col>
        </.table>
      </CompositeComponents.section_panel>

      <CompositeComponents.section_panel body_class="p-4">
        <:title>Recent traces</:title>
        <.table id="model-traces" rows={@detail.recent_records}>
          <:col :let={record} label="When">{record.inserted_at}</:col>
          <:col :let={record} label="Trace">
            <span class="font-mono text-xs">{record.trace_id || "—"}</span>
          </:col>
          <:col :let={record} label="Client">{record.client_key && record.client_key.name}</:col>
          <:col :let={record} label="Outcome">{record.outcome}</:col>
          <:col :let={record} label="Error">{record.error_code || "—"}</:col>
          <:col :let={record} label="Latency">{latency(record.latency_ms)}</:col>
          <:col :let={record} label="Tokens">{record.tokens_in}/{record.tokens_out}</:col>
        </.table>
      </CompositeComponents.section_panel>
    </div>
    """
  end

  defp model_header_subtitle(:index, _detail, _editing),
    do: "Model identity, deployment copies, routing posture, and performance."

  defp model_header_subtitle(:show, %{model: model}, _editing),
    do: "#{model.status} model metadata and deployment posture"

  defp model_header_subtitle(:new, _detail, _editing), do: "Create a shelf identity for a model."

  defp model_header_subtitle(:edit, _detail, %Model{}),
    do: "Update shelf metadata and lifecycle status."

  defp optionize(values), do: Enum.map(values, &{humanize(&1), to_string(&1)})

  defp humanize(value) do
    value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp join_values([]), do: "—"
  defp join_values(nil), do: "—"
  defp join_values(values), do: Enum.map_join(values, ", ", &to_string/1)

  defp model_identity_fields(%{model: model, summary: summary}) do
    [
      %{
        label: "Upstream",
        value: display_value(model.upstream_model_id),
        mono: true,
        compact: true
      },
      %{label: "Family", value: display_value(model.family), mono: false, compact: false},
      %{label: "Version", value: display_value(model.version), mono: true, compact: false},
      %{label: "Revision", value: display_value(model.revision), mono: true, compact: false},
      %{
        label: "Quantization",
        value: display_value(model.quantization),
        mono: true,
        compact: false
      },
      %{label: "Size", value: display_value(model.size), mono: true, compact: false},
      %{label: "Status", value: display_value(model.status), mono: false, compact: false},
      %{label: "Cost", value: display_value(summary.cost), mono: true, compact: false}
    ]
  end

  defp display_value(value) when value in [nil, ""], do: "—"
  defp display_value(value), do: value

  defp metadata_value(%{provider_metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || "—"
  end

  defp metadata_value(_deployment, _key), do: "—"

  defp provider_metadata_fields(deployment) do
    [
      {"Runtime", metadata_value(deployment, "runtime_version")},
      {"Family", metadata_value(deployment, "family")},
      {"Parameters", metadata_value(deployment, "parameter_size")},
      {"Quantization", metadata_value(deployment, "quantization")},
      {"Format", metadata_value(deployment, "format")},
      {"Architecture", metadata_value(deployment, "architecture")},
      {"Context", metadata_value(deployment, "context_window")},
      {"Batch", metadata_value(deployment, "batch_size")},
      {"Queue", metadata_value(deployment, "queue_absolute")},
      {"Languages", metadata_value(deployment, "language_count")},
      {"Voices", metadata_value(deployment, "voice_count")},
      {"Sample rate", metadata_value(deployment, "sample_rate")}
    ]
  end

  defp provider_metadata_present_fields(deployment) do
    Enum.reject(provider_metadata_fields(deployment), fn {_label, value} ->
      missing_metadata?(value)
    end)
  end

  defp provider_metadata_missing_labels(deployment) do
    deployment
    |> provider_metadata_fields()
    |> Enum.filter(fn {_label, value} -> missing_metadata?(value) end)
    |> Enum.map(fn {label, _value} -> label end)
  end

  defp metadata_reported?(deployment, key),
    do: !missing_metadata?(metadata_value(deployment, key))

  defp missing_metadata?(value), do: value in [nil, "", "—"]

  defp running_label(%{provider_metadata: metadata}) when is_map(metadata) do
    case Map.fetch(metadata, "running") do
      {:ok, true} -> "yes"
      {:ok, false} -> "no"
      :error -> "—"
    end
  end

  defp running_label(_deployment), do: "—"

  defp recommendation_class("Lean on"), do: "border-success/40 bg-success/10 text-success"
  defp recommendation_class("Candidate"), do: "border-info/40 bg-info/10 text-info"
  defp recommendation_class("Needs traffic"), do: "border-warning/40 bg-warning/10 text-warning"
  defp recommendation_class("Watch"), do: "border-warning/40 bg-warning/10 text-warning"
  defp recommendation_class("Avoid"), do: "border-error/40 bg-error/10 text-error"
  defp recommendation_class("Disabled"), do: "border-base-300 bg-base-200 text-base-content/70"

  defp recommendation_class(_recommendation),
    do: "border-base-300 bg-base-200 text-base-content/70"

  defp latency(nil), do: "—"
  defp latency(ms), do: "#{ms} ms"
end
