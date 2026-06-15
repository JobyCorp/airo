defmodule AiroWeb.Admin.DeploymentLive do
  @moduledoc "Admin CRUD for deployments — concrete (provider, model) + pricing."
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.Deployment

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Deployments", form: nil, editing: nil)
     |> assign(capabilities: Deployment.capabilities(), classes: Deployment.classes())
     |> assign_providers()
     |> stream(:deployments, list())}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     assign(socket, editing: nil, form: to_form(Config.change_deployment(%Deployment{})))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    deployment = Config.get_deployment!(id)

    {:noreply,
     assign(socket, editing: deployment, form: to_form(Config.change_deployment(deployment)))}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, form: nil, editing: nil)}

  def handle_event("validate", %{"deployment" => params}, socket) do
    changeset = Config.change_deployment(socket.assigns.editing || %Deployment{}, clean(params))
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
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

  defp assign_providers(socket) do
    assign(socket, provider_options: Enum.map(Config.list_providers(), &{&1.name, &1.id}))
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
            <.input field={@form[:model_name]} label="Model name" />
            <.input
              field={@form[:capability]}
              type="select"
              label="Capability"
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
          <:col :let={{_id, d}} label="Capability">{d.capability}</:col>
          <:col :let={{_id, d}} label="Class">{d.class}</:col>
          <:col :let={{_id, d}} label="Enabled">{d.enabled}</:col>
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
      </div>
    </Layouts.app>
    """
  end
end
