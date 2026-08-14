defmodule AiroWeb.Admin.ProviderLive do
  @moduledoc "Admin CRUD for upstream providers (DESIGN §6, §8)."
  use AiroWeb, :live_view

  import AiroWeb.Time, only: [format_at: 1]

  alias Airo.Adapters.Codex.Login
  alias Airo.Config
  alias Airo.Config.Provider
  alias Airo.Config.Secret
  alias Airo.Health
  alias Airo.LocalModels
  alias Airo.Repo
  alias AiroWeb.Admin.RequestDefaultsForm
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
     |> assign(page_title: "Providers", form: nil, editing: nil, detail: nil, codex_login: nil)
     |> assign(rd: RequestDefaultsForm.prefill(%{}))
     |> assign(adapter_types: Provider.adapter_types(), auth_kinds: Provider.auth_kinds())
     |> assign(secret_options: secret_options())
     |> assign(health: health_map(providers))
     |> stream(:providers, providers)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
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
  def handle_event("cancel", _params, socket),
    do: {:noreply, push_navigate(socket, to: provider_return_path(socket.assigns.editing))}

  def handle_event("validate", %{"provider" => params}, socket) do
    rd = RequestDefaultsForm.refresh(params)
    changeset = Config.change_provider(socket.assigns.editing || %Provider{}, prepare(params))
    {:noreply, assign(socket, form: to_form(changeset, action: :validate), rd: rd)}
  end

  def handle_event("save", %{"provider" => params}, socket) do
    case RequestDefaultsForm.fold(params) do
      {:ok, folded} ->
        save(socket, socket.assigns.editing, folded)

      {:error, message} ->
        {:noreply,
         socket
         |> assign(rd: RequestDefaultsForm.refresh(params))
         |> put_flash(:error, "Request defaults JSON: #{message}.")}
    end
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

  def handle_event("codex_start", _params, socket),
    do: {:noreply, assign(socket, codex_login: Login.start())}

  def handle_event("codex_cancel", _params, socket),
    do: {:noreply, assign(socket, codex_login: nil)}

  def handle_event(
        "codex_complete",
        %{"callback" => callback},
        %{assigns: %{detail: %{provider: provider}, codex_login: %{verifier: verifier}}} = socket
      ) do
    with {:ok, tokens} <- Login.exchange(callback, verifier),
         {:ok, _provider} <- persist_codex_credential(provider, tokens) do
      {:noreply,
       socket
       |> assign(codex_login: nil, detail: detail(provider.id))
       |> assign(secret_options: secret_options())
       |> put_flash(:info, "Codex account connected.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Codex sign-in failed: #{inspect(reason)}")}
    end
  end

  # Refresh the tokens on the provider's existing OAuth secret, or mint one and
  # attach it (flipping auth_kind, so a provider created keyless just works).
  defp persist_codex_credential(provider, tokens) do
    attrs = Map.take(tokens, [:value, :refresh_token, :expires_at])

    case provider.credential do
      %Secret{kind: :oauth} = secret ->
        with {:ok, _secret} <- Config.update_secret(secret, attrs), do: {:ok, provider}

      _no_oauth_secret ->
        with {:ok, secret} <-
               Config.create_secret(
                 Map.merge(attrs, %{name: "#{provider.name} Codex OAuth", kind: :oauth})
               ) do
          Config.update_provider(provider, %{"credential_id" => secret.id, "auth_kind" => "oauth"})
        end
    end
  end

  defp list, do: Config.list_providers() |> Repo.preload([:credential, :agent, :deployments])

  defp detail(id) do
    provider =
      id
      |> Config.get_provider!()
      |> Repo.preload([:credential, :agent, deployments: [:model]])

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
      |> Repo.preload([:credential, :agent, deployments: [:model]])

    assign(socket, detail: %{detail | provider: provider, health: provider_status(provider)})
  end

  defp refresh_detail_health(socket), do: socket

  defp health_map(providers), do: Map.new(providers, &{&1.id, provider_status(&1)})

  defp apply_action(socket, :index, _params) do
    providers = list()

    socket
    |> assign(detail: nil, form: nil, editing: nil, page_title: "Providers")
    |> assign(health: health_map(providers))
    |> stream(:providers, providers, reset: true)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    socket
    |> assign(detail: detail(id), form: nil, editing: nil, page_title: "Provider")
    |> assign(codex_login: nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(detail: nil, editing: nil, page_title: "New provider")
    |> assign(form: to_form(Config.change_provider(%Provider{})))
    |> assign(rd: RequestDefaultsForm.prefill(%{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    provider = Config.get_provider!(id)

    socket
    |> assign(detail: nil, editing: provider, page_title: "Edit provider")
    |> assign(form: to_form(Config.change_provider(provider)))
    |> assign(rd: RequestDefaultsForm.prefill(provider.default_params))
  end

  # Validate-time params: a mid-edit JSON error just means "no default_params
  # yet" — the inline error under the editor carries the news.
  defp prepare(params) do
    case RequestDefaultsForm.fold(params) do
      {:ok, folded} -> folded
      {:error, _message} -> params
    end
  end

  defp provider_return_path(%Provider{id: id}), do: ~p"/admin/providers/#{id}"
  defp provider_return_path(_provider), do: ~p"/admin/providers"

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
    with {:ok, params} <- attach_new_credential(params) do
      case Config.create_provider(params) do
        {:ok, provider} ->
          {:noreply,
           socket
           |> assign(form: nil, secret_options: secret_options())
           |> put_flash(:info, "Provider created.")
           |> push_navigate(to: ~p"/admin/providers/#{provider.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:error, message} ->
        {:noreply,
         socket
         |> assign(form: to_form(Config.change_provider(%Provider{}, provider_fields(params))))
         |> put_flash(:error, message)}
    end
  end

  defp save(socket, provider, params) do
    with {:ok, params} <- attach_new_credential(params) do
      case Config.update_provider(provider, params) do
        {:ok, provider} ->
          {:noreply,
           socket
           |> assign(form: nil, editing: nil, secret_options: secret_options())
           |> put_flash(:info, "Provider updated.")
           |> push_navigate(to: ~p"/admin/providers/#{provider.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:error, message} ->
        {:noreply,
         socket
         |> assign(form: to_form(Config.change_provider(provider, provider_fields(params))))
         |> put_flash(:error, message)}
    end
  end

  defp attach_new_credential(params) do
    params = provider_fields(params)
    name = present(params["new_credential_name"])
    value = present(params["new_credential_value"])

    cond do
      is_nil(name) and is_nil(value) ->
        {:ok, Map.drop(params, ["new_credential_name", "new_credential_value"])}

      is_nil(value) ->
        {:error, "New credential value is required."}

      true ->
        attrs = %{
          name: name || default_credential_name(params),
          kind: credential_kind(params),
          value: value
        }

        case Config.create_secret(attrs) do
          {:ok, secret} ->
            {:ok,
             params
             |> Map.drop(["new_credential_name", "new_credential_value"])
             |> Map.put("credential_id", secret.id)}

          {:error, changeset} ->
            {:error, credential_error(changeset)}
        end
    end
  end

  defp provider_fields(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp default_credential_name(params), do: "#{present(params["name"]) || "Provider"} credential"

  defp credential_kind(%{"auth_kind" => kind}) when kind in ["oauth", :oauth], do: :oauth
  defp credential_kind(_params), do: :api_key

  defp credential_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join(", ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> then(&"Credential could not be saved: #{&1}")
  end

  defp secret_options do
    Config.list_secrets()
    |> Enum.map(&{&1.name, &1.id})
  end

  defp credential_name(%{credential: %{name: name}}), do: name
  defp credential_name(_provider), do: "—"

  defp provider_header_subtitle(:index, _detail, _editing),
    do: "Physical upstream model backends."

  defp provider_header_subtitle(:show, %{provider: provider}, _editing),
    do: "#{provider.adapter_type} provider inventory and deployment posture"

  defp provider_header_subtitle(:new, _detail, _editing),
    do: "Register a local upstream provider."

  defp provider_header_subtitle(:edit, _detail, %Provider{}),
    do: "Update connection, auth, and routing eligibility."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="providers">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle={
          provider_header_subtitle(@live_action, @detail, @editing)
        }>
          <:crumb navigate={~p"/admin/providers"}>Providers</:crumb>
          <:crumb :if={@live_action == :show}>{@detail.provider.name}</:crumb>
          <:crumb :if={@live_action == :new}>New provider</:crumb>
          <:crumb :if={@live_action == :edit}>{@editing.name}</:crumb>
          <:actions :if={@live_action == :index}>
            <.button navigate={~p"/admin/providers/new"} variant="primary">New provider</.button>
          </:actions>
          <:actions :if={@live_action == :show}>
            <.button size="sm" phx-click="refresh_detail">Refresh inventory</.button>
            <.button
              size="sm"
              navigate={~p"/admin/providers/#{@detail.provider.id}/edit"}
              variant="primary"
            >
              Edit provider
            </.button>
          </:actions>
          <:actions :if={@live_action in [:new, :edit]}>
            <.button size="sm" navigate={provider_return_path(@editing)}>
              Back
            </.button>
          </:actions>
        </CompositeComponents.page_header>

        <%= cond do %>
          <% @form -> %>
            <.provider_form
              form={@form}
              editing={@editing}
              adapter_types={@adapter_types}
              auth_kinds={@auth_kinds}
              secret_options={@secret_options}
              rd={@rd}
            />
          <% @detail -> %>
            <.provider_detail detail={@detail} codex_login={@codex_login} />
          <% true -> %>
            <.provider_table providers={@streams.providers} health={@health} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :editing, :any, required: true
  attr :adapter_types, :list, required: true
  attr :auth_kinds, :list, required: true
  attr :secret_options, :list, required: true
  attr :rd, :map, required: true

  defp provider_form(assigns) do
    ~H"""
    <.card variant="bordered">
      <:title>Provider settings</:title>
      <.form for={@form} id="provider-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <.input field={@form[:name]} label="Name" />
        <.input
          field={@form[:adapter_type]}
          type="select"
          label="Adapter type"
          options={@adapter_types}
        />
        <.input field={@form[:base_url]} label="Base URL" />
        <.input field={@form[:auth_kind]} type="select" label="Auth kind" options={@auth_kinds} />
        <.input
          field={@form[:credential_id]}
          type="select"
          label="Credential"
          options={@secret_options}
          prompt="No credential"
        />
        <div class="grid gap-4 rounded border border-base-300 p-4 md:grid-cols-2">
          <.input name="provider[new_credential_name]" label="New credential name" value="" />
          <.input
            name="provider[new_credential_value]"
            type="password"
            label="New credential value"
            value=""
          />
        </div>
        <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
        <CompositeComponents.request_defaults
          layer="provider"
          prefix="provider"
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

  attr :providers, :any, required: true
  attr :health, :map, required: true

  defp provider_table(assigns) do
    ~H"""
    <.data_table
      id="providers"
      rows={@providers}
      row_click={fn {_id, p} -> JS.navigate(~p"/admin/providers/#{p.id}") end}
    >
      <:col :let={{_id, p}} label="Name">{p.name}</:col>
      <:col :let={{_id, p}} label="Adapter">{p.adapter_type}</:col>
      <:col :let={{_id, p}} label="Managed by">
        <.link
          :if={p.agent}
          navigate={~p"/admin/agents/#{p.agent.id}"}
          class="text-primary hover:underline"
        >
          {p.agent.host_id}
        </.link>
        <CompositeComponents.tag :if={is_nil(p.agent)} tone="neutral">
          external
        </CompositeComponents.tag>
      </:col>
      <:col :let={{_id, p}} label="Base URL">{p.base_url}</:col>
      <:col :let={{_id, p}} label="Auth">{p.auth_kind}</:col>
      <:col :let={{_id, p}} label="Credential">{credential_name(p)}</:col>
      <:col :let={{_id, p}} label="Enabled">{p.enabled}</:col>
      <:col :let={{_id, p}} label="Health">
        <CompositeComponents.health_status status={@health[p.id] || "unknown"} />
      </:col>
      <:action :let={{_id, p}}>
        <.button
          shape="square"
          size="sm"
          variant="ghost"
          title={"Edit #{p.name}"}
          aria-label={"Edit #{p.name}"}
          navigate={~p"/admin/providers/#{p.id}/edit"}
        >
          <.icon name="hero-pencil-square" class="size-4" />
        </.button>
        <.button
          shape="square"
          size="sm"
          variant="danger"
          class="btn-soft"
          title={"Delete #{p.name}"}
          aria-label={"Delete #{p.name}"}
          phx-click="delete"
          phx-value-id={p.id}
          data-confirm="Delete this provider?"
        >
          <.icon name="hero-trash" class="size-4" />
        </.button>
      </:action>
    </.data_table>
    """
  end

  attr :detail, :map, required: true
  attr :codex_login, :map, default: nil

  defp provider_detail(assigns) do
    ~H"""
    <div class="space-y-6">
      <.codex_account
        :if={@detail.provider.adapter_type == :codex}
        provider={@detail.provider}
        login={@codex_login}
      />
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
          <div>
            <span class="text-base-content/60">Managed by</span>
            <br />
            <.link
              :if={@detail.provider.agent}
              navigate={~p"/admin/agents/#{@detail.provider.agent.id}"}
              class="text-primary hover:underline"
            >
              {@detail.provider.agent.host_id}
            </.link>
            <span :if={is_nil(@detail.provider.agent)}>External (unmanaged)</span>
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
        <.data_table
          id="provider-deployments"
          rows={@detail.provider.deployments}
          row_click={
            fn deployment ->
              deployment.model && JS.navigate(~p"/admin/models/#{deployment.model.id}")
            end
          }
        >
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
              shape="square"
              size="sm"
              variant="ghost"
              title={"Sync #{deployment.model_name}"}
              aria-label={"Sync #{deployment.model_name}"}
              phx-click="sync_deployment"
              phx-value-id={deployment.id}
            >
              <.icon name="hero-arrow-path" class="size-4" />
            </.button>
            <.button
              :if={deployment.model}
              shape="square"
              size="sm"
              variant="ghost"
              title={"Open #{deployment.model.display_name}"}
              aria-label={"Open #{deployment.model.display_name}"}
              href={~p"/admin/models/#{deployment.model.id}"}
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </.button>
          </:action>
        </.data_table>
      </.card>

      <.card variant="bordered">
        <:title>Local catalog</:title>
        <.data_table id="provider-catalog" rows={@detail.catalog}>
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
        </.data_table>
      </.card>
    </div>
    """
  end

  attr :provider, Provider, required: true
  attr :login, :map, default: nil

  # "Sign in with ChatGPT" for a Codex provider: the OAuth redirect goes to
  # localhost:1455 (the Codex CLI's listener — the only redirect the client id
  # allows), so the operator opens the link, signs in, and pastes the resulting
  # callback URL back here.
  defp codex_account(assigns) do
    ~H"""
    <.card variant="bordered">
      <:eyebrow>ChatGPT subscription</:eyebrow>
      <:title>Codex account</:title>
      <div :if={codex_connected?(@provider)} class="text-sm text-base-content/70">
        Connected via <span class="font-mono">{@provider.credential.name}</span>
        <span :if={@provider.credential.expires_at}>
          — access token expires {format_at(@provider.credential.expires_at)}
        </span>
      </div>
      <div :if={!codex_connected?(@provider)} class="text-sm text-base-content/70">
        Not connected. Sign in with the ChatGPT account whose Codex subscription
        should serve this provider.
      </div>

      <div :if={is_nil(@login)} class="mt-4">
        <.button size="sm" variant="primary" phx-click="codex_start">
          {if codex_connected?(@provider), do: "Re-connect account", else: "Sign in with ChatGPT"}
        </.button>
      </div>

      <div :if={@login} class="mt-4 space-y-4">
        <ol class="list-inside list-decimal space-y-1 text-sm text-base-content/70">
          <li>Open the sign-in link and authenticate with ChatGPT.</li>
          <li>
            The browser lands on <span class="font-mono">localhost:1455</span>
            — a page that won't load; that's expected.
          </li>
          <li>Copy the full address from the address bar and paste it below.</li>
        </ol>
        <.button size="sm" href={@login.url} target="_blank" rel="noopener">
          <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open sign-in page
        </.button>
        <.form for={%{}} phx-submit="codex_complete" class="space-y-4">
          <.input
            name="callback"
            value=""
            label="Pasted callback URL (or code)"
            placeholder="http://localhost:1455/auth/callback?code=…"
          />
          <div class="flex gap-2">
            <.button size="sm" variant="primary">Complete sign-in</.button>
            <.button size="sm" type="button" phx-click="codex_cancel">Cancel</.button>
          </div>
        </.form>
      </div>
    </.card>
    """
  end

  defp codex_connected?(%Provider{auth_kind: :oauth, credential: %Secret{kind: :oauth}}), do: true
  defp codex_connected?(_provider), do: false

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
