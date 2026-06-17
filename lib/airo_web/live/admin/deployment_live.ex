defmodule AiroWeb.Admin.DeploymentLive do
  @moduledoc "Admin CRUD for deployments — concrete (provider, model) + pricing."
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.Deployment
  alias Airo.Health
  alias AiroWeb.CompositeComponents

  # Re-poll per-deployment health (kept in ETS by Airo.Health.Prober) so the
  # admin table reflects an upstream going down without a manual reload.
  @health_refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_health, @health_refresh_ms)
    deployments = list()

    {:ok,
     socket
     |> assign(page_title: "Deployments", form: nil, editing: nil)
     |> assign(capabilities: Deployment.capabilities(), classes: Deployment.classes())
     |> assign(model_options: [], model_error: nil, models_provider_id: nil)
     |> assign(health: health_map(deployments))
     |> stream(:health_events, Health.list_events(25))
     |> assign_providers()
     |> stream(:deployments, deployments)}
  end

  @impl true
  def handle_info(:refresh_health, socket) do
    Process.send_after(self(), :refresh_health, @health_refresh_ms)
    deployments = list()

    {:noreply,
     socket
     |> assign(health: health_map(deployments))
     |> stream(:health_events, Health.list_events(25), reset: true)
     |> stream(:deployments, deployments, reset: true)}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(editing: nil, form: to_form(Config.change_deployment(%Deployment{})))
     |> assign_models(nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    deployment = Config.get_deployment!(id)

    {:noreply,
     socket
     |> assign(editing: deployment, form: to_form(Config.change_deployment(deployment)))
     |> assign_models(deployment.provider_id)}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, form: nil, editing: nil)}

  def handle_event("validate", %{"deployment" => params}, socket) do
    changeset = Config.change_deployment(socket.assigns.editing || %Deployment{}, clean(params))

    {:noreply,
     socket
     |> assign(form: to_form(changeset, action: :validate))
     |> assign_models(params["provider_id"])}
  end

  def handle_event("save", %{"deployment" => params}, socket) do
    save(socket, socket.assigns.editing, clean(params))
  end

  def handle_event("delete", %{"id" => id}, socket) do
    deployment = Config.get_deployment!(id)
    {:ok, _} = Config.delete_deployment(deployment)
    {:noreply, stream_delete(socket, :deployments, deployment)}
  end

  defp save(socket, nil, params) do
    case Config.create_deployment(params) do
      {:ok, d} ->
        {:noreply,
         socket
         |> stream_insert(:deployments, with_provider(d))
         |> assign(form: nil)
         |> put_flash(:info, "Deployment created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, deployment, params) do
    case Config.update_deployment(deployment, params) do
      {:ok, d} ->
        {:noreply,
         socket
         |> stream_insert(:deployments, with_provider(d))
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Deployment updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp list, do: Config.list_deployments() |> Airo.Repo.preload(:provider)
  defp with_provider(d), do: Airo.Repo.preload(d, :provider)

  defp health_map(deployments),
    do: Map.new(deployments, &{&1.id, to_string(Health.status(&1.id))})

  defp assign_providers(socket) do
    assign(socket, provider_options: Enum.map(Config.list_providers(), &{&1.name, &1.id}))
  end

  # Populate the model picker from the chosen provider's upstream catalog. Only
  # refetch when the provider actually changes (validate fires on every keystroke),
  # and degrade to a free-text field + hint when the upstream can't be listed.
  defp assign_models(socket, provider_id) when provider_id in [nil, ""],
    do: assign(socket, model_options: [], model_error: nil, models_provider_id: nil)

  defp assign_models(%{assigns: %{models_provider_id: provider_id}} = socket, provider_id),
    do: socket

  defp assign_models(socket, provider_id) do
    case Config.get_provider!(provider_id) |> Airo.Models.list() do
      {:ok, models} ->
        assign(socket,
          model_options: models,
          model_error: models == [] && empty_catalog_message(),
          models_provider_id: provider_id
        )

      {:error, reason} ->
        assign(socket,
          model_options: [],
          model_error: model_error_message(reason),
          models_provider_id: provider_id
        )
    end
  end

  defp empty_catalog_message,
    do: "This provider reports no models — load one upstream, or enter the model name manually."

  defp model_error_message(:unsupported),
    do: "This provider's adapter can't list models — enter the model name manually."

  defp model_error_message(_reason),
    do: "Couldn't reach the provider to list models — enter the model name manually."

  # Make sure the current value is selectable even if the upstream no longer
  # advertises it, so editing an existing deployment never silently drops it.
  defp model_select_options(options, current) when current in [nil, ""], do: options

  defp model_select_options(options, current) do
    if current in options, do: options, else: [current | options]
  end

  # Drop blanks so optional enum/number fields don't fail casting / clobber.
  defp clean(params), do: for({k, v} <- params, v != "", into: %{}, do: {k, v})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="deployments">
      <div class="mx-auto max-w-6xl space-y-6 px-6 py-8">
        <.header>
          Deployments
          <:subtitle>A concrete model on a provider, with pricing.</:subtitle>
          <:actions><.button phx-click="new" variant="primary">New deployment</.button></:actions>
        </.header>

        <.card :if={@form} variant="bordered">
          <:title>{if @editing, do: "Edit deployment", else: "New deployment"}</:title>
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
            <.input
              field={@form[:provider_id]}
              type="select"
              label="Provider"
              options={@provider_options}
              prompt="Select a provider"
            />
            <.input
              :if={@model_options == []}
              field={@form[:model_name]}
              label="Model name"
            />
            <.input
              :if={@model_options != []}
              field={@form[:model_name]}
              type="select"
              label="Model name"
              options={model_select_options(@model_options, @form[:model_name].value)}
              prompt="Select a model"
            />
            <p :if={@model_error} class="text-sm text-warning">{@model_error}</p>
            <.input
              field={@form[:capabilities]}
              type="select"
              multiple
              label="Capabilities"
              options={@capabilities}
            />
            <.input
              field={@form[:class]}
              type="select"
              label="Class"
              options={@classes}
              prompt="(none)"
            />
            <.input field={@form[:tool_use]} type="checkbox" label="Tool use" />
            <.input field={@form[:context_window]} type="number" label="Context window" />
            <.input field={@form[:price_input]} label="Price input (per 1k)" />
            <.input field={@form[:price_output]} label="Price output (per 1k)" />
            <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
            <.button variant="primary">Save</.button>
          </.form>
          <:actions><.button phx-click="cancel">Cancel</.button></:actions>
        </.card>

        <.table id="deployments" rows={@streams.deployments}>
          <:col :let={{_id, d}} label="Provider">{d.provider && d.provider.name}</:col>
          <:col :let={{_id, d}} label="Model">{d.model_name}</:col>
          <:col :let={{_id, d}} label="Capabilities">
            {Enum.map_join(d.capabilities, ", ", &to_string/1)}
          </:col>
          <:col :let={{_id, d}} label="Class">{d.class}</:col>
          <:col :let={{_id, d}} label="Enabled">{d.enabled}</:col>
          <:col :let={{_id, d}} label="Health">
            <CompositeComponents.health_status status={@health[d.id] || "unknown"} />
          </:col>
          <:action :let={{_id, d}}>
            <.button size="sm" phx-click="edit" phx-value-id={d.id}>Edit</.button>
            <.button
              size="sm"
              phx-click="delete"
              phx-value-id={d.id}
              data-confirm="Delete this deployment?"
            >
              Delete
            </.button>
          </:action>
        </.table>

        <.card variant="bordered">
          <:title>Health transitions</:title>
          Recent deployment health changes from probes and live dispatches.
          <.table id="health-events" rows={@streams.health_events}>
            <:col :let={{_id, event}} label="When">{event.inserted_at}</:col>
            <:col :let={{_id, event}} label="Provider">
              {event.provider && event.provider.name}
            </:col>
            <:col :let={{_id, event}} label="Model">
              {event.deployment && event.deployment.model_name}
            </:col>
            <:col :let={{_id, event}} label="Status">
              <CompositeComponents.health_status status={to_string(event.status)} />
            </:col>
            <:col :let={{_id, event}} label="Source">{event.source}</:col>
            <:col :let={{_id, event}} label="Latency">{latency(event.latency_ms)}</:col>
            <:col :let={{_id, event}} label="Reason">{event.reason || "—"}</:col>
          </.table>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp latency(nil), do: "—"
  defp latency(ms), do: "#{ms} ms"
end
