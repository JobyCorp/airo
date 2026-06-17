defmodule AiroWeb.Admin.ModelLive do
  @moduledoc "Model Shelf admin surface for model identity, deployments, and performance."
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.Model
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
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(detail: ModelShelf.get_detail!(id), form: nil, editing: nil)
     |> assign(page_title: "Model Shelf")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(detail: nil, form: nil, editing: nil)
     |> stream(:models, ModelShelf.list_summaries(), reset: true)}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: to_form(Config.change_model(%Model{})))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    model = Config.get_model!(id)
    {:noreply, assign(socket, editing: model, form: to_form(Config.change_model(model)))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

  def handle_event("validate", %{"model" => params}, socket) do
    changeset = Config.change_model(socket.assigns.editing || %Model{}, clean(params))
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"model" => params}, socket) do
    save(socket, socket.assigns.editing, clean(params))
  end

  defp save(socket, nil, params) do
    case Config.create_model(params) do
      {:ok, _model} ->
        {:noreply,
         socket
         |> refresh_after_save()
         |> put_flash(:info, "Model created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, model, params) do
    case Config.update_model(model, params) do
      {:ok, _model} ->
        {:noreply,
         socket
         |> refresh_after_save()
         |> put_flash(:info, "Model updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp refresh_after_save(socket) do
    socket =
      case socket.assigns.detail do
        %{model: model} -> assign(socket, detail: ModelShelf.get_detail!(model.id))
        _ -> stream(socket, :models, ModelShelf.list_summaries(), reset: true)
      end

    assign(socket, form: nil, editing: nil)
  end

  defp clean(params), do: for({k, v} <- params, v != "", into: %{}, do: {k, v})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="models">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <.header>
          Model Shelf
          <:subtitle>Model identity, deployment copies, routing posture, and performance.</:subtitle>
          <:actions>
            <.button phx-click="new" variant="primary">New model</.button>
          </:actions>
        </.header>

        <.card :if={@form} variant="bordered">
          <:title>{if @editing, do: "Edit model", else: "New model"}</:title>
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
            <.input
              field={@form[:notes]}
              type="textarea"
              label="Notes"
              class="md:col-span-2"
            />
            <div class="flex gap-2 md:col-span-2">
              <.button variant="primary">Save</.button>
              <.button type="button" phx-click="cancel">Cancel</.button>
            </div>
          </.form>
        </.card>

        <%= if @detail do %>
          <.detail detail={@detail} />
        <% else %>
          <.shelf models={@streams.models} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :models, :any, required: true

  defp shelf(assigns) do
    ~H"""
    <.table id="models" rows={@models}>
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
        <.button size="sm" href={~p"/admin/models/#{summary.model.id}"}>Open</.button>
        <.button size="sm" phx-click="edit" phx-value-id={summary.model.id}>Edit</.button>
      </:action>
    </.table>
    """
  end

  attr :detail, :map, required: true

  defp detail(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <.button href={~p"/admin/models"}>Back to shelf</.button>
        <.button phx-click="edit" phx-value-id={@detail.model.id} variant="primary">
          Edit metadata
        </.button>
      </div>

      <div class="grid gap-4 md:grid-cols-3 xl:grid-cols-6">
        <.card variant="bordered">
          <:eyebrow>Deployments</:eyebrow>
          <:title>
            {@detail.summary.enabled_deployment_count}/{@detail.summary.deployment_count}
          </:title>
          Enabled copies.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Health</:eyebrow>
          <:title>{@detail.summary.health}</:title>
          Aggregate posture.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Requests</:eyebrow>
          <:title>{@detail.summary.requests}</:title>
          Recorded calls.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Error rate</:eyebrow>
          <:title>{@detail.summary.error_rate}</:title>
          From usage rows.
        </.card>
        <.card variant="bordered">
          <:eyebrow>p95 latency</:eyebrow>
          <:title>{latency(@detail.summary.p95_latency_ms)}</:title>
          Served calls.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Fallbacks</:eyebrow>
          <:title>{@detail.summary.fallback_rate}</:title>
          Later candidates.
        </.card>
      </div>

      <.card variant="bordered">
        <:title>{@detail.model.display_name}</:title>
        <div class="grid gap-4 text-sm md:grid-cols-2 xl:grid-cols-4">
          <div>
            <span class="text-base-content/60">Upstream</span> <br />{@detail.model.upstream_model_id}
          </div>
          <div>
            <span class="text-base-content/60">Family</span> <br />{@detail.model.family || "—"}
          </div>
          <div>
            <span class="text-base-content/60">Version</span> <br />{@detail.model.version || "—"}
          </div>
          <div>
            <span class="text-base-content/60">Revision</span> <br />{@detail.model.revision || "—"}
          </div>
          <div>
            <span class="text-base-content/60">Quantization</span>
            <br />{@detail.model.quantization || "—"}
          </div>
          <div><span class="text-base-content/60">Size</span> <br />{@detail.model.size || "—"}</div>
          <div><span class="text-base-content/60">Status</span> <br />{@detail.model.status}</div>
          <div><span class="text-base-content/60">Cost</span> <br />{@detail.summary.cost}</div>
        </div>
        <p :if={@detail.model.notes} class="mt-4 text-sm">{@detail.model.notes}</p>
      </.card>

      <.card variant="bordered">
        <:title>Version performance</:title>
        <.table id="model-versions" rows={@detail.version_summaries}>
          <:col :let={row} label="Version">{row.version}</:col>
          <:col :let={row} label="Revision">{row.revision || "—"}</:col>
          <:col :let={row} label="First seen">{row.first_seen}</:col>
          <:col :let={row} label="Last seen">{row.last_seen}</:col>
          <:col :let={row} label="Requests">{row.requests}</:col>
          <:col :let={row} label="Errors">{row.error_rate}</:col>
          <:col :let={row} label="p50">{latency(row.p50_latency_ms)}</:col>
          <:col :let={row} label="p95">{latency(row.p95_latency_ms)}</:col>
          <:col :let={row} label="Fallbacks">{row.fallback_rate}</:col>
          <:col :let={row} label="Cost">{row.cost}</:col>
        </.table>
      </.card>

      <.card variant="bordered">
        <:title>Deployment copies</:title>
        <.table id="model-deployments" rows={@detail.deployment_summaries}>
          <:col :let={row} label="Provider">{row.provider && row.provider.name}</:col>
          <:col :let={row} label="Model id">{row.deployment.model_name}</:col>
          <:col :let={row} label="Health">
            <CompositeComponents.health_status status={to_string(row.health)} />
          </:col>
          <:col :let={row} label="Enabled">{row.deployment.enabled}</:col>
          <:col :let={row} label="Capabilities">{join_values(row.deployment.capabilities)}</:col>
          <:col :let={row} label="Requests">{row.requests}</:col>
          <:col :let={row} label="Errors">{row.error_rate}</:col>
          <:col :let={row} label="p50">{latency(row.p50_latency_ms)}</:col>
          <:col :let={row} label="p95">{latency(row.p95_latency_ms)}</:col>
          <:col :let={row} label="Fallbacks">{row.fallback_rate}</:col>
        </.table>
      </.card>

      <.card variant="bordered">
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
      </.card>

      <.card variant="bordered">
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
      </.card>

      <.card variant="bordered">
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
      </.card>
    </div>
    """
  end

  defp optionize(values), do: Enum.map(values, &{humanize(&1), to_string(&1)})

  defp humanize(value) do
    value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp join_values([]), do: "—"
  defp join_values(nil), do: "—"
  defp join_values(values), do: Enum.map_join(values, ", ", &to_string/1)

  defp latency(nil), do: "—"
  defp latency(ms), do: "#{ms} ms"
end
