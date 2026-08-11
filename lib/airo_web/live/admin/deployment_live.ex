defmodule AiroWeb.Admin.DeploymentLive do
  @moduledoc "Admin CRUD for deployments — concrete (provider, model) + pricing."
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.Deployment
  alias Airo.Health
  alias AiroWeb.Admin.RequestDefaultsForm
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
     |> assign(page_title: "Deployments", form: nil, editing: nil, detail: nil)
     |> assign(disable_thinking: false, rd: RequestDefaultsForm.prefill(%{}))
     |> assign(capabilities: Deployment.capabilities(), classes: Deployment.classes())
     |> assign(model_options: [], model_error: nil, models_provider_id: nil)
     |> assign_model_id_options()
     |> assign(health: health_map(deployments))
     |> stream(:health_events, Health.list_events(25))
     |> assign_providers()
     |> stream(:deployments, deployments)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
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
  def handle_event("cancel", _params, socket),
    do: {:noreply, push_navigate(socket, to: deployment_return_path(socket.assigns.editing))}

  def handle_event("validate", %{"deployment" => params}, socket) do
    disable_thinking = params["disable_thinking"] == "true"
    rd = RequestDefaultsForm.refresh(params)
    params = params |> clean() |> fold_defaults() |> apply_thinking(disable_thinking)
    changeset = Config.change_deployment(socket.assigns.editing || %Deployment{}, params)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, action: :validate))
     |> assign(disable_thinking: disable_thinking, rd: rd)
     |> assign_models(params["provider_id"])}
  end

  def handle_event("save", %{"deployment" => params}, socket) do
    disable_thinking = params["disable_thinking"] == "true"

    case params |> clean() |> RequestDefaultsForm.fold() do
      {:ok, folded} ->
        save(socket, socket.assigns.editing, apply_thinking(folded, disable_thinking))

      {:error, message} ->
        {:noreply,
         socket
         |> assign(rd: RequestDefaultsForm.refresh(params), disable_thinking: disable_thinking)
         |> put_flash(:error, "Request defaults JSON: #{message}.")}
    end
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
         |> assign(form: nil)
         |> put_flash(:info, "Deployment created.")
         |> push_navigate(to: ~p"/admin/deployments/#{d.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, deployment, params) do
    case Config.update_deployment(deployment, params) do
      {:ok, d} ->
        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Deployment updated.")
         |> push_navigate(to: ~p"/admin/deployments/#{d.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp list, do: Config.list_deployments() |> Airo.Repo.preload(:provider)
  defp with_detail(d), do: Airo.Repo.preload(d, [:provider, :model])

  defp apply_action(socket, :index, _params) do
    deployments = list()

    socket
    |> assign(page_title: "Deployments", detail: nil, form: nil, editing: nil)
    |> assign(health: health_map(deployments))
    |> stream(:health_events, Health.list_events(25), reset: true)
    |> stream(:deployments, deployments, reset: true)
    |> assign_models(nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    deployment = id |> Config.get_deployment!() |> with_detail()

    socket
    |> assign(page_title: "Deployment", detail: deployment, form: nil, editing: nil)
    |> assign_models(nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New deployment", detail: nil, editing: nil)
    |> assign(form: to_form(Config.change_deployment(%Deployment{})), disable_thinking: false)
    |> assign(rd: RequestDefaultsForm.prefill(%{}))
    |> assign_models(nil)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    deployment = Config.get_deployment!(id)

    socket
    |> assign(page_title: "Edit deployment", detail: nil, editing: deployment)
    |> assign(form: to_form(Config.change_deployment(deployment)))
    |> assign(disable_thinking: thinking_disabled?(deployment.default_params))
    |> assign(rd: RequestDefaultsForm.prefill(without_thinking(deployment.default_params)))
    |> assign_models(deployment.provider_id)
  end

  # The request-defaults section must not show the enable_thinking key — the
  # toggle above it owns that one; put_enable_thinking(…, false) strips it.
  defp without_thinking(default_params) when is_map(default_params),
    do: put_enable_thinking(default_params, false)

  defp without_thinking(_default_params), do: %{}

  defp deployment_return_path(%Deployment{id: id}), do: ~p"/admin/deployments/#{id}"
  defp deployment_return_path(_deployment), do: ~p"/admin/deployments"

  defp health_map(deployments),
    do: Map.new(deployments, &{&1.id, to_string(Health.status(&1.id))})

  defp assign_providers(socket) do
    assign(socket, provider_options: Enum.map(Config.list_providers(), &{&1.name, &1.id}))
  end

  defp assign_model_id_options(socket) do
    options =
      Config.list_models()
      |> Enum.map(&{"#{&1.display_name} (#{&1.upstream_model_id})", &1.id})

    assign(socket, model_id_options: options)
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

  defp deployment_header_subtitle(:index, _detail, _editing),
    do: "A concrete model on a provider, with pricing."

  defp deployment_header_subtitle(:show, %{provider: provider}, _editing),
    do: "#{provider && provider.name} deployment configuration"

  defp deployment_header_subtitle(:new, _detail, _editing),
    do: "Attach a provider model to the gateway."

  defp deployment_header_subtitle(:edit, _detail, %Deployment{}),
    do: "Update routing eligibility, capabilities, and pricing."

  # Make sure the current value is selectable even if the upstream no longer
  # advertises it, so editing an existing deployment never silently drops it.
  defp model_select_options(options, current) when current in [nil, ""], do: options

  defp model_select_options(options, current) do
    if current in options, do: options, else: [current | options]
  end

  # Drop blanks so optional enum/number fields don't fail casting / clobber.
  # Checkbox groups submit one blank sentinel so clearing all options validates
  # as an empty list instead of preserving the old array value.
  defp clean(params) do
    params
    |> Enum.map(fn {key, value} -> {key, clean_value(value)} end)
    |> Enum.reject(fn {_key, value} -> value == "" end)
    |> Map.new()
  end

  defp clean_value(values) when is_list(values),
    do: Enum.reject(values, &(&1 in ["", nil]))

  defp clean_value(value), do: value

  # Validate-time fold: a mid-edit JSON parse error just means "no
  # default_params yet" — the inline error under the editor carries the news.
  defp fold_defaults(params) do
    case RequestDefaultsForm.fold(params) do
      {:ok, folded} -> folded
      {:error, _message} -> params
    end
  end

  # "Disable thinking" is not a column — it's a per-request default that rides
  # `default_params.chat_template_kwargs.enable_thinking`, which the gateway
  # deep-merges into every upstream chat body (Airo.Gateway.Params). Fold the
  # checkbox into the map the request-defaults section just built, preserving
  # its keys; the toggle owns exactly this one key.
  defp apply_thinking(params, disable_thinking) do
    base = params["default_params"] || %{}

    params
    |> Map.delete("disable_thinking")
    |> Map.put("default_params", put_enable_thinking(base, disable_thinking))
  end

  # Set enable_thinking:false when disabling; drop the key when enabling so the
  # engine default (thinking on) rules and default_params stays minimal. Empty
  # bags are pruned so we don't persist `%{"chat_template_kwargs" => %{}}`.
  defp put_enable_thinking(params, true) do
    kwargs = params |> Map.get("chat_template_kwargs", %{}) |> Map.put("enable_thinking", false)
    Map.put(params, "chat_template_kwargs", kwargs)
  end

  defp put_enable_thinking(params, false) do
    kwargs = params |> Map.get("chat_template_kwargs", %{}) |> Map.delete("enable_thinking")

    if map_size(kwargs) == 0,
      do: Map.delete(params, "chat_template_kwargs"),
      else: Map.put(params, "chat_template_kwargs", kwargs)
  end

  defp thinking_disabled?(default_params) when is_map(default_params),
    do: get_in(default_params, ["chat_template_kwargs", "enable_thinking"]) == false

  defp thinking_disabled?(_default_params), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="deployments">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle={
          deployment_header_subtitle(@live_action, @detail, @editing)
        }>
          <:crumb navigate={~p"/admin/deployments"}>Deployments</:crumb>
          <:crumb :if={@live_action == :show}>{@detail.model_name}</:crumb>
          <:crumb :if={@live_action == :new}>New deployment</:crumb>
          <:crumb :if={@live_action == :edit}>{@editing.model_name}</:crumb>
          <:actions :if={@live_action == :index}>
            <.button navigate={~p"/admin/deployments/new"} variant="primary">
              New deployment
            </.button>
          </:actions>
          <:actions :if={@live_action == :show}>
            <.button
              size="sm"
              navigate={~p"/admin/deployments/#{@detail.id}/edit"}
              variant="primary"
            >
              Edit deployment
            </.button>
          </:actions>
          <:actions :if={@live_action in [:new, :edit]}>
            <.button size="sm" navigate={deployment_return_path(@editing)}>
              Back
            </.button>
          </:actions>
        </CompositeComponents.page_header>

        <%= cond do %>
          <% @form -> %>
            <.deployment_form
              form={@form}
              editing={@editing}
              provider_options={@provider_options}
              model_options={@model_options}
              model_id_options={@model_id_options}
              model_error={@model_error}
              capabilities={@capabilities}
              classes={@classes}
              disable_thinking={@disable_thinking}
              rd={@rd}
            />
          <% @detail -> %>
            <.deployment_detail deployment={@detail} health={@health[@detail.id] || "unknown"} />
          <% true -> %>
            <.deployment_table deployments={@streams.deployments} health={@health} />
            <.health_events events={@streams.health_events} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :editing, :any, required: true
  attr :provider_options, :list, required: true
  attr :model_options, :list, required: true
  attr :model_id_options, :list, required: true
  attr :model_error, :string, default: nil
  attr :capabilities, :list, required: true
  attr :classes, :list, required: true
  attr :disable_thinking, :boolean, default: false
  attr :rd, :map, required: true

  defp deployment_form(assigns) do
    ~H"""
    <.card variant="bordered">
      <:title>Deployment settings</:title>
      <.form
        for={@form}
        id="deployment-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <.input
          field={@form[:provider_id]}
          type="select"
          label="Provider"
          options={@provider_options}
          prompt="Select a provider"
        />
        <.input :if={@model_options == []} field={@form[:model_name]} label="Model name" />
        <.input
          :if={@model_options != []}
          field={@form[:model_name]}
          type="select"
          label="Model name"
          options={model_select_options(@model_options, @form[:model_name].value)}
          prompt="Select a model"
        />
        <.input
          field={@form[:model_id]}
          type="select"
          label="Shelf model"
          options={@model_id_options}
          prompt="Infer from model name"
        />
        <p :if={@model_error} class="text-sm text-warning">{@model_error}</p>
        <.checkbox_group field={@form[:capabilities]} label="Capabilities" options={@capabilities} />
        <.input field={@form[:class]} type="select" label="Class" options={@classes} prompt="(none)" />
        <.input field={@form[:tool_use]} type="checkbox" label="Tool use" />
        <div>
          <.input
            type="checkbox"
            name="deployment[disable_thinking]"
            value={@disable_thinking}
            label="Disable thinking"
          />
          <p class="text-xs text-base-content/55">
            Sends <span class="font-mono">chat_template_kwargs.enable_thinking=false</span>
            on every request to this deployment, so the model skips reasoning traces.
            Per-request values override it.
          </p>
        </div>
        <.input field={@form[:context_window]} type="number" label="Context window" />
        <.input field={@form[:price_input]} label="Price input (per 1k)" />
        <.input field={@form[:price_output]} label="Price output (per 1k)" />
        <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
        <CompositeComponents.request_defaults
          layer="deployment"
          prefix="deployment"
          values={@rd.values}
          json={@rd.json}
          error={@rd.error}
          class="border-t border-base-content/10 pt-4"
        />
        <div class="flex gap-2">
          <.button variant="primary">Save</.button>
          <.button type="button" phx-click="cancel">Cancel</.button>
        </div>
      </.form>
    </.card>
    """
  end

  attr :deployments, :any, required: true
  attr :health, :map, required: true

  defp deployment_table(assigns) do
    ~H"""
    <.data_table
      id="deployments"
      rows={@deployments}
      row_click={fn {_id, d} -> JS.navigate(~p"/admin/deployments/#{d.id}") end}
    >
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
        <.button
          shape="square"
          size="sm"
          variant="ghost"
          title={"Edit #{d.model_name}"}
          aria-label={"Edit #{d.model_name}"}
          navigate={~p"/admin/deployments/#{d.id}/edit"}
        >
          <.icon name="hero-pencil-square" class="size-4" />
        </.button>
        <.button
          shape="square"
          size="sm"
          variant="danger"
          class="btn-soft"
          title={"Delete #{d.model_name}"}
          aria-label={"Delete #{d.model_name}"}
          phx-click="delete"
          phx-value-id={d.id}
          data-confirm="Delete this deployment?"
        >
          <.icon name="hero-trash" class="size-4" />
        </.button>
      </:action>
    </.data_table>
    """
  end

  attr :deployment, Deployment, required: true
  attr :health, :string, required: true

  defp deployment_detail(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
        <.card variant="bordered">
          <:eyebrow>Provider</:eyebrow>
          <:title>{@deployment.provider && @deployment.provider.name}</:title>
          {@deployment.provider && @deployment.provider.adapter_type}
        </.card>
        <.card variant="bordered">
          <:eyebrow>Health</:eyebrow>
          <:title>{@health}</:title>
          Current prober signal.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Enabled</:eyebrow>
          <:title>{@deployment.enabled}</:title>
          Routing eligibility.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Capabilities</:eyebrow>
          <:title>{length(@deployment.capabilities)}</:title>
          {Enum.map_join(@deployment.capabilities, ", ", &to_string/1)}
        </.card>
        <.card variant="bordered">
          <:eyebrow>Class</:eyebrow>
          <:title>{@deployment.class || "—"}</:title>
          Routing tier.
        </.card>
      </div>

      <.card variant="bordered">
        <:title>{@deployment.model_name}</:title>
        <div class="grid gap-4 text-sm md:grid-cols-2 xl:grid-cols-4">
          <div>
            <span class="text-base-content/60">Shelf model</span>
            <br />{(@deployment.model && @deployment.model.display_name) || "—"}
          </div>
          <div>
            <span class="text-base-content/60">Tool use</span>
            <br />{@deployment.tool_use}
          </div>
          <div>
            <span class="text-base-content/60">Thinking</span>
            <br />{if thinking_disabled?(@deployment.default_params), do: "disabled", else: "on"}
          </div>
          <div>
            <span class="text-base-content/60">Context window</span>
            <br />{@deployment.context_window || "—"}
          </div>
          <div>
            <span class="text-base-content/60">Price input/output</span>
            <br />{@deployment.price_input || "—"} / {@deployment.price_output || "—"}
          </div>
        </div>
        <div :if={map_size(@deployment.default_params || %{}) > 0} class="mt-4 text-sm">
          <span class="text-base-content/60">Request defaults</span>
          <pre class="mt-1 overflow-x-auto rounded bg-base-300/40 p-3 font-mono text-xs text-base-content/85">{Jason.encode!(@deployment.default_params, pretty: true)}</pre>
        </div>
      </.card>
    </div>
    """
  end

  attr :events, :any, required: true

  defp health_events(assigns) do
    ~H"""
    <.card variant="bordered">
      <:title>Health transitions</:title>
      Recent deployment health changes from probes and live dispatches.
      <.data_table id="health-events" rows={@events}>
        <:col :let={{_id, event}} label="When">{event.inserted_at}</:col>
        <:col :let={{_id, event}} label="Provider">{event.provider && event.provider.name}</:col>
        <:col :let={{_id, event}} label="Model">
          {event.deployment && event.deployment.model_name}
        </:col>
        <:col :let={{_id, event}} label="Status">
          <CompositeComponents.health_status status={to_string(event.status)} />
        </:col>
        <:col :let={{_id, event}} label="Source">{event.source}</:col>
        <:col :let={{_id, event}} label="Latency">{latency(event.latency_ms)}</:col>
        <:col :let={{_id, event}} label="Reason">{event.reason || "—"}</:col>
      </.data_table>
    </.card>
    """
  end

  defp latency(nil), do: "—"
  defp latency(ms), do: "#{ms} ms"
end
