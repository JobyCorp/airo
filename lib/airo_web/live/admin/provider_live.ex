defmodule AiroWeb.Admin.ProviderLive do
  @moduledoc "Admin CRUD for upstream providers (DESIGN §6, §8)."
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.Provider

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Providers", form: nil, editing: nil)
     |> assign(adapter_types: Provider.adapter_types(), auth_kinds: Provider.auth_kinds())
     |> stream(:providers, Config.list_providers())}
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

        <.table id="providers" rows={@streams.providers}>
          <:col :let={{_id, p}} label="Name">{p.name}</:col>
          <:col :let={{_id, p}} label="Adapter">{p.adapter_type}</:col>
          <:col :let={{_id, p}} label="Base URL">{p.base_url}</:col>
          <:col :let={{_id, p}} label="Auth">{p.auth_kind}</:col>
          <:col :let={{_id, p}} label="Enabled">{p.enabled}</:col>
          <:action :let={{_id, p}}>
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
      </div>
    </Layouts.app>
    """
  end
end
