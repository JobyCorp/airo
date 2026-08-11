defmodule AiroWeb.Admin.AliasLive do
  @moduledoc """
  Admin for aliases (the logical handles consumers call) and their routing
  candidates (DESIGN §8, §9). Basic fields are edited via the form; candidates
  are added/removed directly on the alias being edited.
  """
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.Alias
  alias AiroWeb.Admin.RequestDefaultsForm
  alias AiroWeb.CompositeComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Aliases", form: nil, editing: nil, detail: nil)
     |> assign(rd: RequestDefaultsForm.prefill(%{}))
     |> assign(capabilities: Alias.capabilities(), strategies: Alias.strategies())
     |> assign(deployment_options: deployment_options())
     |> assign(
       routers: [{"Off", "none"}, {"On — use the system classifier", "classify"}],
       modes: [{"Shadow — log only", "shadow"}, {"Enforce — apply tier", "enforce"}]
     )
     |> stream(:aliases, list())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("cancel", _params, socket),
    do: {:noreply, push_navigate(socket, to: alias_return_path(socket.assigns.editing))}

  def handle_event("validate", %{"alias" => params}, socket) do
    rd = RequestDefaultsForm.refresh(params)
    changeset = Config.change_alias(socket.assigns.editing || %Alias{}, prepare(params))
    {:noreply, assign(socket, form: to_form(changeset, action: :validate), rd: rd)}
  end

  def handle_event("save", %{"alias" => params}, socket) do
    case RequestDefaultsForm.fold(normalize(params)) do
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

  # Routing participation only (S16): turn the system classifier on/off for this
  # alias and pick shadow/enforce. The classifier itself (engine, model, ladder)
  # lives in the system setting at `/admin/routing` — not here.
  def handle_event("routing_submit", params, socket) do
    router = if params["router"] == "classify", do: :classify, else: :none
    mode = if params["router_mode"] == "enforce", do: :enforce, else: :shadow

    case Config.update_alias(socket.assigns.editing, %{router: router, router_mode: mode}) do
      {:ok, a} ->
        {:noreply,
         socket
         |> put_flash(:info, routing_flash(router))
         |> assign(editing: Config.get_alias_with_candidates!(a.id))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save routing.")}
    end
  end

  defp routing_flash(:classify), do: "Routing enabled — this alias uses the system classifier."
  defp routing_flash(:none), do: "Routing disabled."

  defp save(socket, nil, params) do
    case Config.create_alias(params) do
      {:ok, a} ->
        {:noreply,
         socket
         |> put_flash(:info, "Alias created — add routing candidates below.")
         |> push_navigate(to: ~p"/admin/aliases/#{a.id}/edit")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, alias_, params) do
    case Config.update_alias(alias_, params) do
      {:ok, a} ->
        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> put_flash(:info, "Alias updated.")
         |> push_navigate(to: ~p"/admin/aliases/#{a.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp reload_editing(socket, id),
    do: assign(socket, editing: Config.get_alias_with_candidates!(id))

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Aliases", form: nil, editing: nil, detail: nil)
    |> stream(:aliases, list(), reset: true)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    socket
    |> assign(
      page_title: "Alias",
      detail: Config.get_alias_with_candidates!(id),
      form: nil,
      editing: nil
    )
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New alias", detail: nil, editing: nil)
    |> assign(form: to_form(Config.change_alias(%Alias{})))
    |> assign(rd: RequestDefaultsForm.prefill(%{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    alias_ = Config.get_alias_with_candidates!(id)

    socket
    |> assign(page_title: "Edit alias", detail: nil, editing: alias_, preview: nil)
    |> assign(form: to_form(Config.change_alias(alias_)))
    |> assign(rd: RequestDefaultsForm.prefill(alias_.default_params))
  end

  defp alias_return_path(%Alias{id: id}), do: ~p"/admin/aliases/#{id}"
  defp alias_return_path(_alias), do: ~p"/admin/aliases"

  defp list, do: Config.list_aliases() |> Enum.map(&with_count/1)
  defp with_count(a), do: a |> Airo.Repo.preload(:candidates)

  defp deployment_options do
    Config.list_deployments()
    |> Airo.Repo.preload(:provider)
    |> Enum.map(&{"#{&1.provider.name} · #{&1.model_name}", &1.id})
  end

  # Validate-time params: a mid-edit JSON error just means "no default_params
  # yet" — the inline error under the editor carries the news.
  defp prepare(params) do
    case RequestDefaultsForm.fold(normalize(params)) do
      {:ok, folded} -> folded
      {:error, _message} -> normalize(params)
    end
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

  defp alias_header_subtitle(:index, _detail, _editing),
    do: "Logical handles consumers call, routed to deployments."

  defp alias_header_subtitle(:show, %Alias{} = alias_, _editing),
    do: "#{alias_.capability} routed with #{alias_.strategy}"

  defp alias_header_subtitle(:new, _detail, _editing), do: "Create a logical routing handle."

  defp alias_header_subtitle(:edit, _detail, %Alias{}),
    do: "Update routing behavior and candidate participation."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="aliases">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle={
          alias_header_subtitle(@live_action, @detail, @editing)
        }>
          <:crumb navigate={~p"/admin/aliases"}>Aliases</:crumb>
          <:crumb :if={@live_action == :show}>{@detail.name}</:crumb>
          <:crumb :if={@live_action == :new}>New alias</:crumb>
          <:crumb :if={@live_action == :edit}>{@editing.name}</:crumb>
          <:actions :if={@live_action == :index}>
            <.button navigate={~p"/admin/aliases/new"} variant="primary">New alias</.button>
          </:actions>
          <:actions :if={@live_action == :show}>
            <.button size="sm" navigate={~p"/admin/aliases/#{@detail.id}/edit"} variant="primary">
              Edit alias
            </.button>
          </:actions>
          <:actions :if={@live_action in [:new, :edit]}>
            <.button size="sm" navigate={alias_return_path(@editing)}>Back</.button>
          </:actions>
        </CompositeComponents.page_header>

        <%= cond do %>
          <% @form -> %>
            <.alias_form
              form={@form}
              editing={@editing}
              capabilities={@capabilities}
              strategies={@strategies}
              deployment_options={@deployment_options}
              routers={@routers}
              modes={@modes}
              rd={@rd}
            />
          <% @detail -> %>
            <.alias_detail alias={@detail} />
          <% true -> %>
            <.alias_table aliases={@streams.aliases} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :editing, :any, required: true
  attr :capabilities, :list, required: true
  attr :strategies, :list, required: true
  attr :deployment_options, :list, required: true
  attr :routers, :list, required: true
  attr :modes, :list, required: true
  attr :rd, :map, required: true

  defp alias_form(assigns) do
    ~H"""
    <div class="space-y-6">
      <.card variant="bordered">
        <:title>Alias settings</:title>
        <.form for={@form} id="alias-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Name (e.g. chat-deep)" />
          <.input field={@form[:capability]} type="select" label="Capability" options={@capabilities} />
          <.input field={@form[:strategy]} type="select" label="Strategy" options={@strategies} />
          <.input
            field={@form[:fallback]}
            label="Fallback aliases"
            value={Enum.join(@form[:fallback].value || [], ", ")}
            placeholder="comma-separated alias names"
          />
          <CompositeComponents.request_defaults
            layer="alias"
            prefix="alias"
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

      <.card :if={@editing} variant="bordered">
        <:title>Routing candidates — {@editing.name}</:title>

        <.table id="candidates" rows={@editing.candidates}>
          <:col :let={c} label="Deployment">{c.deployment && c.deployment.model_name}</:col>
          <:col :let={c} label="Weight">{c.weight}</:col>
          <:col :let={c} label="Priority">{c.priority}</:col>
          <:action :let={c}>
            <.button
              shape="square"
              size="sm"
              variant="danger"
              title="Remove candidate"
              aria-label="Remove candidate"
              phx-click="remove_candidate"
              phx-value-id={c.id}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </.button>
          </:action>
        </.table>

        <.form
          for={%{}}
          id="alias-candidate-form"
          phx-submit="add_candidate"
          class="mt-4 flex flex-wrap items-end gap-3"
        >
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

      <.alias_routing_card :if={@editing} editing={@editing} routers={@routers} modes={@modes} />
    </div>
    """
  end

  attr :editing, :any, required: true
  attr :routers, :list, required: true
  attr :modes, :list, required: true

  defp alias_routing_card(assigns) do
    assigns =
      assign(assigns,
        router_value: to_string(assigns.editing.router),
        mode_value: to_string(assigns.editing.router_mode)
      )

    ~H"""
    <.card variant="bordered">
      <:eyebrow>Classification routing</:eyebrow>
      <:title>Tier routing — {@editing.name}</:title>
      <p class="mb-4 text-sm text-base-content/70">
        When on, this alias classifies the prompt and sets <code>route.class</code>
        to a tier.
        Shadow logs the prediction (<code>gateway.route.classified</code>) without changing what
        is served; enforce applies it. An explicit caller <code>route.class</code>
        always wins.
        The classifier itself (engine, model, thresholds) is configured once in <.link
          navigate={~p"/admin/routing"}
          class="text-primary hover:underline"
        >Routing settings</.link>.
      </p>

      <.form for={%{}} id="alias-routing-form" phx-submit="routing_submit" class="space-y-4">
        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            name="router"
            type="select"
            label="Classifier routing"
            options={@routers}
            value={@router_value}
          />
          <.input name="router_mode" type="select" label="Mode" options={@modes} value={@mode_value} />
        </div>
        <.button type="submit" variant="primary">Save routing</.button>
      </.form>
    </.card>
    """
  end

  attr :aliases, :any, required: true

  defp alias_table(assigns) do
    ~H"""
    <.table
      id="aliases"
      rows={@aliases}
      row_click={fn {_id, a} -> JS.navigate(~p"/admin/aliases/#{a.id}") end}
    >
      <:col :let={{_id, a}} label="Name">{a.name}</:col>
      <:col :let={{_id, a}} label="Capability">{a.capability}</:col>
      <:col :let={{_id, a}} label="Strategy">{a.strategy}</:col>
      <:col :let={{_id, a}} label="Candidates">{length(a.candidates)}</:col>
      <:action :let={{_id, a}}>
        <.button
          shape="square"
          size="sm"
          variant="ghost"
          title={"Edit #{a.name}"}
          aria-label={"Edit #{a.name}"}
          navigate={~p"/admin/aliases/#{a.id}/edit"}
        >
          <.icon name="hero-pencil-square" class="size-4" />
        </.button>
        <.button
          shape="square"
          size="sm"
          variant="danger"
          title={"Delete #{a.name}"}
          aria-label={"Delete #{a.name}"}
          phx-click="delete"
          phx-value-id={a.id}
          data-confirm="Delete this alias?"
        >
          <.icon name="hero-trash" class="size-4" />
        </.button>
      </:action>
    </.table>
    """
  end

  attr :alias, Alias, required: true

  defp alias_detail(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-4 md:grid-cols-3">
        <.card variant="bordered">
          <:eyebrow>Capability</:eyebrow>
          <:title>{@alias.capability}</:title>
          Requested resource class.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Strategy</:eyebrow>
          <:title>{@alias.strategy}</:title>
          Candidate selection mode.
        </.card>
        <.card variant="bordered">
          <:eyebrow>Candidates</:eyebrow>
          <:title>{length(@alias.candidates)}</:title>
          Active routing targets.
        </.card>
      </div>

      <.card variant="bordered">
        <:title>Routing candidates</:title>
        <.table id="alias-candidates" rows={@alias.candidates}>
          <:col :let={candidate} label="Deployment">
            {candidate.deployment && candidate.deployment.model_name}
          </:col>
          <:col :let={candidate} label="Weight">{candidate.weight}</:col>
          <:col :let={candidate} label="Priority">{candidate.priority}</:col>
        </.table>
      </.card>
    </div>
    """
  end
end
