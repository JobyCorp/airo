defmodule AiroWeb.Admin.AliasLive do
  @moduledoc """
  Admin for aliases (the logical handles consumers call) and their routing
  candidates (DESIGN §8, §9). Basic fields are edited via the form; candidates
  are added/removed directly on the alias being edited.
  """
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.Alias

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Aliases", form: nil, editing: nil)
     |> assign(capabilities: Alias.capabilities(), strategies: Alias.strategies())
     |> assign(deployment_options: deployment_options())
     |> stream(:aliases, list())}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: to_form(Config.change_alias(%Alias{})))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    alias_ = Config.get_alias_with_candidates!(id)
    {:noreply, assign(socket, editing: alias_, form: to_form(Config.change_alias(alias_)))}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, form: nil, editing: nil)}

  def handle_event("validate", %{"alias" => params}, socket) do
    changeset = Config.change_alias(socket.assigns.editing || %Alias{}, normalize(params))
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"alias" => params}, socket) do
    save(socket, socket.assigns.editing, normalize(params))
  end

  def handle_event("delete", %{"id" => id}, socket) do
    alias_ = Config.get_alias!(id)
    {:ok, _} = Config.delete_alias(alias_)
    {:noreply, stream_delete(socket, :aliases, alias_)}
  end

  def handle_event("add_candidate", %{"candidate" => params}, socket) do
    alias_ = socket.assigns.editing

    case Config.add_alias_candidate(alias_.id, params) do
      {:ok, _} ->
        {:noreply, reload_editing(socket, alias_.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add candidate (already present?).")}
    end
  end

  def handle_event("remove_candidate", %{"id" => id}, socket) do
    Config.delete_alias_candidate(id)
    {:noreply, reload_editing(socket, socket.assigns.editing.id)}
  end

  defp save(socket, nil, params) do
    case Config.create_alias(params) do
      {:ok, a} ->
        {:noreply,
         socket
         |> stream_insert(:aliases, with_count(a))
         |> assign(
           editing: Config.get_alias_with_candidates!(a.id),
           form: to_form(Config.change_alias(a))
         )
         |> put_flash(:info, "Alias created — add routing candidates below.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, alias_, params) do
    case Config.update_alias(alias_, params) do
      {:ok, a} ->
        {:noreply,
         socket
         |> stream_insert(:aliases, with_count(a))
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Alias updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp reload_editing(socket, id),
    do: assign(socket, editing: Config.get_alias_with_candidates!(id))

  defp list, do: Config.list_aliases() |> Enum.map(&with_count/1)
  defp with_count(a), do: a |> Airo.Repo.preload(:candidates)

  defp deployment_options do
    Config.list_deployments()
    |> Airo.Repo.preload(:provider)
    |> Enum.map(&{"#{&1.provider.name} · #{&1.model_name}", &1.id})
  end

  # fallback comes from the form as a comma-separated string.
  defp normalize(params) do
    case params["fallback"] do
      string when is_binary(string) ->
        Map.put(
          params,
          "fallback",
          string |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        )

      _ ->
        params
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="aliases">
      <div class="mx-auto max-w-6xl space-y-6 px-6 py-8">
        <.header>
          Aliases
          <:subtitle>Logical handles consumers call, routed to deployments.</:subtitle>
          <:actions><.button phx-click="new" variant="primary">New alias</.button></:actions>
        </.header>

        <.card :if={@form} variant="bordered">
          <:title>{if @editing, do: "Edit alias", else: "New alias"}</:title>
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
            <.input field={@form[:name]} label="Name (e.g. chat-deep)" />
            <.input
              field={@form[:capability]}
              type="select"
              label="Capability"
              options={@capabilities}
            />
            <.input field={@form[:strategy]} type="select" label="Strategy" options={@strategies} />
            <.input
              field={@form[:fallback]}
              label="Fallback aliases"
              value={Enum.join(@form[:fallback].value || [], ", ")}
              placeholder="comma-separated alias names"
            />
            <.button variant="primary">Save</.button>
          </.form>
          <:actions><.button phx-click="cancel">Cancel</.button></:actions>
        </.card>

        <.card :if={@editing} variant="bordered">
          <:title>Routing candidates — {@editing.name}</:title>

          <.table id="candidates" rows={@editing.candidates}>
            <:col :let={c} label="Deployment">{c.deployment && c.deployment.model_name}</:col>
            <:col :let={c} label="Weight">{c.weight}</:col>
            <:col :let={c} label="Priority">{c.priority}</:col>
            <:action :let={c}>
              <.button size="sm" phx-click="remove_candidate" phx-value-id={c.id}>Remove</.button>
            </:action>
          </.table>

          <.form for={%{}} phx-submit="add_candidate" class="mt-4 flex flex-wrap items-end gap-3">
            <.input
              name="candidate[deployment_id]"
              value=""
              type="select"
              label="Deployment"
              options={@deployment_options}
              prompt="Select a deployment"
            />
            <.input name="candidate[weight]" value="100" type="number" label="Weight" />
            <.input name="candidate[priority]" value="0" type="number" label="Priority" />
            <.button variant="primary">Add</.button>
          </.form>
        </.card>

        <.table id="aliases" rows={@streams.aliases}>
          <:col :let={{_id, a}} label="Name">{a.name}</:col>
          <:col :let={{_id, a}} label="Capability">{a.capability}</:col>
          <:col :let={{_id, a}} label="Strategy">{a.strategy}</:col>
          <:col :let={{_id, a}} label="Candidates">{length(a.candidates)}</:col>
          <:action :let={{_id, a}}>
            <.button size="sm" phx-click="edit" phx-value-id={a.id}>Edit</.button>
            <.button
              size="sm"
              phx-click="delete"
              phx-value-id={a.id}
              data-confirm="Delete this alias?"
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
