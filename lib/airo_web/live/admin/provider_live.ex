defmodule AiroWeb.Admin.ProviderLive do
  @moduledoc "Admin CRUD for upstream providers (DESIGN §6, §8)."
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.Provider
  alias Airo.Health
  alias Airo.LocalModels
  alias Airo.Repo
  alias AiroWeb.CompositeComponents

  # Re-poll provider health (aggregated from its deployments' ETS health) so a
  # down upstream surfaces without a manual reload.
  @health_refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_health, @health_refresh_ms)
    providers = list()

    {:ok,
     socket
     |> assign(page_title: "Providers", form: nil, editing: nil, detail: nil)
     |> assign(adapter_types: Provider.adapter_types(), auth_kinds: Provider.auth_kinds())
     |> assign(health: health_map(providers))
     |> stream(:providers, providers)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(detail: detail(id), form: nil, editing: nil, page_title: "Provider")}
  end

  def handle_params(_params, _uri, socket) do
    providers = list()

    {:noreply,
     socket
     |> assign(detail: nil, form: nil, editing: nil, page_title: "Providers")
     |> assign(health: health_map(providers))
     |> stream(:providers, providers, reset: true)}
  end

  @impl true
  def handle_info(:refresh_health, socket) do
    Process.send_after(self(), :refresh_health, @health_refresh_ms)
    providers = list()

    socket =
      socket
      |> assign(health: health_map(providers))
      |> stream(:providers, providers, reset: true)

    {:noreply, refresh_detail_health(socket)}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: to_form(Config.change_provider(%Provider{})))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    provider = Config.get_provider!(id)
    {:noreply, assign(socket, editing: provider, form: to_form(Config.change_provider(provider)))}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, form: nil, editing: nil)}

  def handle_event("validate", %{"provider" => params}, socket) do
    changeset = Config.change_provider(socket.assigns.editing || %Provider{}, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"provider" => params}, socket) do
    save(socket, socket.assigns.editing, params)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    provider = Config.get_provider!(id)
    {:ok, _} = Config.delete_provider(provider)
    {:noreply, stream_delete(socket, :providers, provider)}
  end

  def handle_event(
        "refresh_detail",
        _params,
        %{assigns: %{detail: %{provider: provider}}} = socket
      ) do
    {:noreply, assign(socket, detail: detail(provider.id))}
  end

  def handle_event("sync_deployment", %{"id" => id}, socket) do
    deployment = Config.get_deployment!(id)

    case LocalModels.sync_deployment(deployment) do
      {:ok, synced} ->
        {:noreply,
         socket
         |> refresh_detail_for_provider(synced.provider_id)
         |> put_flash(:info, "Provider metadata synced.")}

      {:error, :unsupported} ->
        {:noreply, put_flash(socket, :error, "This provider does not expose local metadata.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Metadata sync failed: #{inspect(reason)}")}
    end
  end

  defp list, do: Config.list_providers() |> Airo.Repo.preload(:deployments)

  defp detail(id) do
    provider =
      id
      |> Config.get_provider!()
      |> Repo.preload(deployments: [:model])

    capabilities = LocalModels.capabilities(provider)
    {catalog, catalog_error} = local_catalog(provider, capabilities)
    {runtime, runtime_error} = local_runtime(provider, capabilities)

    %{
      provider: provider,
      capabilities: capabilities,
      catalog: catalog,
      catalog_error: catalog_error,
      runtime: runtime,
      runtime_error: runtime_error,
      running: Map.get(runtime, :running, []),
      health: provider_status(provider)
    }
  end

  defp local_catalog(provider, capabilities) do
    if :catalog in capabilities do
      case LocalModels.catalog(provider) do
        {:ok, models} -> {models, nil}
        {:error, reason} -> {[], inspect(reason)}
      end
    else
      {[], "This provider does not expose a local catalog."}
    end
  end

  defp local_runtime(provider, capabilities) do
    if :runtime_info in capabilities do
      case LocalModels.runtime_info(provider) do
        {:ok, runtime} -> {runtime, nil}
        {:error, reason} -> {%{}, inspect(reason)}
      end
    else
      {%{}, nil}
    end
  end

  defp refresh_detail_for_provider(socket, provider_id) do
    case socket.assigns.detail do
      %{provider: %{id: ^provider_id}} -> assign(socket, detail: detail(provider_id))
      _ -> socket
    end
  end

  defp refresh_detail_health(%{assigns: %{detail: %{provider: provider} = detail}} = socket) do
    provider =
      provider.id
      |> Config.get_provider!()
      |> Repo.preload(deployments: [:model])

    assign(socket, detail: %{detail | provider: provider, health: provider_status(provider)})
  end

  defp refresh_detail_health(socket), do: socket

  defp health_map(providers), do: Map.new(providers, &{&1.id, provider_status(&1)})

  # A provider is as healthy as its worst deployment: any :down → "down",
  # else any :up → "up", else "unknown" (no deployments / never probed).
  defp provider_status(provider) do
    statuses = Enum.map(provider.deployments, &Health.status(&1.id))

    cond do
      Enum.any?(statuses, &(&1 == :down)) -> "down"
      Enum.any?(statuses, &(&1 == :up)) -> "up"
      true -> "unknown"
    end
  end

  defp save(socket, nil, params) do
    case Config.create_provider(params) do
      {:ok, provider} ->
        {:noreply,
         socket
         |> stream_insert(:providers, provider)
         |> assign(form: nil)
         |> put_flash(:info, "Provider created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, provider, params) do
    case Config.update_provider(provider, params) do
      {:ok, provider} ->
        {:noreply,
         socket
         |> stream_insert(:providers, provider)
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Provider updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="providers">
      <div class="mx-auto max-w-6xl space-y-6 px-6 py-8">
        <.header>
          Providers
          <:subtitle>Physical upstream model backends.</:subtitle>
          <:actions><.button phx-click="new" variant="primary">New provider</.button></:actions>
        </.header>

        <.card :if={@form} variant="bordered">
          <:title>{if @editing, do: "Edit provider", else: "New provider"}</:title>
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
            <.input field={@form[:name]} label="Name" />
            <.input
              field={@form[:adapter_type]}
              type="select"
              label="Adapter type"
              options={@adapter_types}
            />
            <.input field={@form[:base_url]} label="Base URL" />
            <.input field={@form[:auth_kind]} type="select" label="Auth kind" options={@auth_kinds} />
            <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
            <.button variant="primary">Save</.button>
          </.form>
          <:actions><.button phx-click="cancel">Cancel</.button></:actions>
        </.card>

        <%= if @detail do %>
          <.provider_detail detail={@detail} />
        <% else %>
          <.table id="providers" rows={@streams.providers}>
            <:col :let={{_id, p}} label="Name">{p.name}</:col>
            <:col :let={{_id, p}} label="Adapter">{p.adapter_type}</:col>
            <:col :let={{_id, p}} label="Base URL">{p.base_url}</:col>
            <:col :let={{_id, p}} label="Auth">{p.auth_kind}</:col>
            <:col :let={{_id, p}} label="Enabled">{p.enabled}</:col>
            <:col :let={{_id, p}} label="Health">
              <CompositeComponents.health_status status={@health[p.id] || "unknown"} />
            </:col>
            <:action :let={{_id, p}}>
              <.button size="sm" href={~p"/admin/providers/#{p.id}"}>Open</.button>
              <.button size="sm" phx-click="edit" phx-value-id={p.id}>Edit</.button>
              <.button
                size="sm"
                phx-click="delete"
                phx-value-id={p.id}
                data-confirm="Delete this provider?"
              >
                Delete
              </.button>
            </:action>
          </.table>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :detail, :map, required: true

  defp provider_detail(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <.button href={~p"/admin/providers"}>Back to providers</.button>
        <div class="flex gap-2">
          <.button phx-click="refresh_detail">Refresh inventory</.button>
          <.button phx-click="edit" phx-value-id={@detail.provider.id} variant="primary">
            Edit provider
          </.button>
        </div>
      </div>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
        <.card variant="bordered">
          <:eyebrow>Provider</:eyebrow>
          <:title>{@detail.provider.name}</:title>
          {@detail.provider.adapter_type}
        </.card>
        <.card variant="bordered">
          <:eyebrow>Enabled</:eyebrow>
          <:title>{@detail.provider.enabled}</:title>
          Gateway routing eligibility.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Health</:eyebrow>
          <:title>{@detail.health}</:title>
          Current prober signal.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Deployments</:eyebrow>
          <:title>{length(@detail.provider.deployments)}</:title>
          Configured copies.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Catalog</:eyebrow>
          <:title>{length(@detail.catalog)}</:title>
          Advertised local models.
        </.card>
      </div>

      <.card variant="bordered">
        <:title>Runtime</:title>
        <div class="grid gap-4 text-sm md:grid-cols-2 xl:grid-cols-4">
          <div>
            <span class="text-base-content/60">Base URL</span>
            <br />{@detail.provider.base_url}
          </div>
          <div>
            <span class="text-base-content/60">Auth</span>
            <br />{@detail.provider.auth_kind}
          </div>
          <div>
            <span class="text-base-content/60">Capabilities</span>
            <br />{join_values(@detail.capabilities)}
          </div>
          <div>
            <span class="text-base-content/60">Loaded/running</span>
            <br />{length(@detail.running)}
          </div>
        </div>
        <p :if={@detail.catalog_error} class="mt-4 text-sm text-error">
          Catalog unavailable: {@detail.catalog_error}
        </p>
        <p :if={@detail.runtime_error} class="mt-4 text-sm text-error">
          Runtime unavailable: {@detail.runtime_error}
        </p>
      </.card>

      <.card variant="bordered">
        <:title>Deployments</:title>
        <.table id="provider-deployments" rows={@detail.provider.deployments}>
          <:col :let={deployment} label="Model">
            <div>{deployment.model_name}</div>
            <div :if={deployment.model} class="font-mono text-xs text-base-content/60">
              {deployment.model.display_name}
            </div>
          </:col>
          <:col :let={deployment} label="Health">
            <CompositeComponents.health_status status={to_string(Health.status(deployment.id))} />
          </:col>
          <:col :let={deployment} label="Enabled">{deployment.enabled}</:col>
          <:col :let={deployment} label="Capabilities">{join_values(deployment.capabilities)}</:col>
          <:col :let={deployment} label="Synced">
            {metadata_value(deployment, "synced_at")}
          </:col>
          <:col :let={deployment} label="Type">{metadata_value(deployment, "type")}</:col>
          <:action :let={deployment}>
            <.button
              :if={:inspect_model in @detail.capabilities}
              size="sm"
              phx-click="sync_deployment"
              phx-value-id={deployment.id}
            >
              Sync
            </.button>
            <.button :if={deployment.model} size="sm" href={~p"/admin/models/#{deployment.model.id}"}>
              Model
            </.button>
          </:action>
        </.table>
      </.card>

      <.card variant="bordered">
        <:title>Local catalog</:title>
        <.table id="provider-catalog" rows={@detail.catalog}>
          <:col :let={model} label="Model">{catalog_value(model, :id)}</:col>
          <:col :let={model} label="Type">{catalog_value(model, :type)}</:col>
          <:col :let={model} label="Family">{catalog_value(model, :family)}</:col>
          <:col :let={model} label="Backend">{catalog_value(model, :backend)}</:col>
          <:col :let={model} label="Context">{catalog_value(model, :context_window)}</:col>
          <:col :let={model} label="Batch">{catalog_value(model, :batch_size)}</:col>
          <:col :let={model} label="Queue">{catalog_value(model, :queue_absolute)}</:col>
          <:col :let={model} label="Languages">{catalog_value(model, :language_count)}</:col>
          <:col :let={model} label="Voices">{catalog_value(model, :voice_count)}</:col>
          <:col :let={model} label="Running">
            {if running?(@detail.running, model), do: "yes", else: "no"}
          </:col>
        </.table>
      </.card>
    </div>
    """
  end

  defp join_values([]), do: "—"
  defp join_values(nil), do: "—"
  defp join_values(values), do: Enum.map_join(values, ", ", &to_string/1)

  defp metadata_value(%{provider_metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || "—"
  end

  defp metadata_value(_deployment, _key), do: "—"

  defp catalog_value(model, key) when is_map(model), do: Map.get(model, key) || "—"
  defp catalog_value(_model, _key), do: "—"

  defp running?(running, model) do
    id = catalog_value(model, :id)

    Enum.any?(running, fn running_model ->
      catalog_value(running_model, :id) == id or catalog_value(running_model, :display_name) == id
    end)
  end
end
