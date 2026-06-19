defmodule AiroWeb.Admin.AliasLive do
  @moduledoc """
  Admin for aliases (the logical handles consumers call) and their routing
  candidates (DESIGN §8, §9). Basic fields are edited via the form; candidates
  are added/removed directly on the alias being edited.
  """
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.{Alias, Deployment}
  alias Airo.Routing.Classifier
  alias AiroWeb.CompositeComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Aliases", form: nil, editing: nil, detail: nil, preview: nil)
     |> assign(capabilities: Alias.capabilities(), strategies: Alias.strategies())
     |> assign(deployment_options: deployment_options())
     |> assign(
       routers: [{"Off", "none"}, {"On — classify prompt", "classify"}],
       modes: [{"Shadow — log only", "shadow"}, {"Enforce — apply tier", "enforce"}],
       input_modes: [{"Last user message", "last_user"}, {"All turns", "all"}],
       classes: Enum.map(Deployment.classes(), &to_string/1),
       classify_aliases: classify_alias_names()
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

  # The classifier-routing config (router on/off + the router_config map: mode,
  # classifier, thresholds, labels) is operator-editable here, so calibration and
  # the shadow->enforce flip need no code or SQL. Save persists only on the explicit
  # Save button (intent=save); every other submit — including Enter in the prompt
  # field — is a side-effect-free Test, so an accidental submit can't overwrite the
  # live config.
  def handle_event("routing_submit", %{"intent" => "save"} = params, socket) do
    router = if params["router"] == "classify", do: :classify, else: :none
    config = build_router_config(params["rc"] || %{})

    if router == :classify and config["labels"] == [] do
      {:noreply,
       put_flash(socket, :error, "Add at least one label to enable classifier routing.")}
    else
      case Config.update_alias(socket.assigns.editing, %{router: router, router_config: config}) do
        {:ok, a} ->
          {:noreply,
           socket
           |> put_flash(:info, routing_flash(router))
           |> assign(editing: Config.get_alias_with_candidates!(a.id), preview: nil)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not save routing config.")}
      end
    end
  end

  # "Test" (or any non-save submit) — run the classifier on the *current form*
  # config (unsaved) so the operator can tune thresholds and see the prediction
  # without sending traffic or persisting anything.
  def handle_event("routing_submit", params, socket) do
    config = build_router_config(params["rc"] || %{})
    prompt = trimmed(params["preview_prompt"])
    alias_ = %{socket.assigns.editing | router: :classify, router_config: config}

    result =
      if prompt == "" do
        :empty
      else
        Classifier.class_for(alias_, %{"messages" => [%{"role" => "user", "content" => prompt}]})
      end

    {:noreply, assign(socket, preview: %{prompt: prompt, result: result, config: config})}
  end

  defp routing_flash(:classify), do: "Classifier routing saved."
  defp routing_flash(:none), do: "Classifier routing disabled."

  # Rebuild the router_config map from flat form params. Labels arrive indexed
  # (`rc[labels][0][...]`); blank rows are dropped so an empty row doubles as "add".
  defp build_router_config(rc) do
    %{
      "mode" => if(rc["mode"] == "enforce", do: "enforce", else: "shadow"),
      "classifier" => trimmed(rc["classifier"]),
      "input" => if(rc["input"] == "all", do: "all", else: "last_user"),
      "hypothesis_template" =>
        blank_default(rc["hypothesis_template"], "This request requires {}."),
      "default_class" => blank_default(rc["default_class"], "edge"),
      "timeout_ms" => parse_int(rc["timeout_ms"], 200),
      "labels" => build_labels(rc["labels"])
    }
  end

  defp build_labels(labels) when is_map(labels) do
    labels
    |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, l} ->
      %{
        "label" => trimmed(l["label"]),
        "class" => trimmed(l["class"]),
        "min" => parse_float(l["min"], 0.5)
      }
    end)
    |> Enum.reject(&(&1["label"] == ""))
  end

  defp build_labels(_), do: []

  defp trimmed(nil), do: ""
  defp trimmed(s) when is_binary(s), do: String.trim(s)

  defp blank_default(s, default) do
    case trimmed(s) do
      "" -> default
      other -> other
    end
  end

  defp parse_int(s, default) do
    case Integer.parse(to_string(s)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_float(s, default) do
    case Float.parse(to_string(s)) do
      {f, _} -> f
      _ -> default
    end
  end

  defp classify_alias_names do
    Config.list_aliases()
    |> Enum.filter(&(&1.capability == :classify))
    |> Enum.map(& &1.name)
  end

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
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    alias_ = Config.get_alias_with_candidates!(id)

    socket
    |> assign(page_title: "Edit alias", detail: nil, editing: alias_, preview: nil)
    |> assign(form: to_form(Config.change_alias(alias_)))
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
              input_modes={@input_modes}
              classes={@classes}
              classify_aliases={@classify_aliases}
              preview={@preview}
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
  attr :input_modes, :list, required: true
  attr :classes, :list, required: true
  attr :classify_aliases, :list, required: true
  attr :preview, :any, required: true

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
            <.icon_button
              icon="hero-x-mark"
              label="Remove candidate"
              variant="danger"
              phx-click="remove_candidate"
              phx-value-id={c.id}
            />
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

      <.alias_routing_card
        :if={@editing}
        editing={@editing}
        routers={@routers}
        modes={@modes}
        input_modes={@input_modes}
        classes={@classes}
        classify_aliases={@classify_aliases}
        preview={@preview}
      />
    </div>
    """
  end

  attr :editing, :any, required: true
  attr :routers, :list, required: true
  attr :modes, :list, required: true
  attr :input_modes, :list, required: true
  attr :classes, :list, required: true
  attr :classify_aliases, :list, required: true
  attr :preview, :any, required: true

  defp alias_routing_card(assigns) do
    # Render from the just-tested config (if any) so unsaved edits survive a Test,
    # otherwise from the saved config.
    rc = (assigns.preview && assigns.preview.config) || assigns.editing.router_config || %{}
    label_rows = Enum.with_index((rc["labels"] || []) ++ [%{}, %{}])

    assigns =
      assign(assigns,
        rc: rc,
        label_rows: label_rows,
        router_value: to_string(assigns.editing.router)
      )

    ~H"""
    <.card variant="bordered">
      <:eyebrow>Classification routing</:eyebrow>
      <:title>Tier routing — {@editing.name}</:title>
      <p class="mb-4 text-sm text-base-content/70">
        Classify the prompt and set <code>route.class</code> to a tier. Shadow logs the
        prediction (<code>gateway.route.classified</code>) without changing what is served;
        enforce applies it. An explicit caller <code>route.class</code> always wins.
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
          <.input
            name="rc[mode]"
            type="select"
            label="Mode"
            options={@modes}
            value={@rc["mode"] || "shadow"}
          />
          <.input
            name="rc[classifier]"
            type="select"
            label="Classifier alias"
            options={@classify_aliases}
            value={@rc["classifier"]}
            prompt="Select a :classify alias"
          />
          <.input
            name="rc[input]"
            type="select"
            label="Text to classify"
            options={@input_modes}
            value={@rc["input"] || "last_user"}
          />
          <.input
            name="rc[default_class]"
            type="select"
            label="Default tier (no match)"
            options={@classes}
            value={@rc["default_class"] || "edge"}
          />
          <.input
            name="rc[timeout_ms]"
            type="number"
            label="Timeout (ms)"
            value={@rc["timeout_ms"] || 200}
          />
        </div>

        <.input
          name="rc[hypothesis_template]"
          label="Hypothesis template ({} is replaced by each label)"
          value={@rc["hypothesis_template"] || "This request requires {}."}
        />

        <div class="space-y-2">
          <p class="text-sm font-medium">
            Labels — highest tier first; the first whose score ≥ its min wins. Clear a label's text to remove it.
          </p>
          <div
            :for={{label, i} <- @label_rows}
            class="grid grid-cols-1 gap-2 sm:grid-cols-[1fr_9rem_7rem]"
          >
            <.input
              name={"rc[labels][#{i}][label]"}
              value={label["label"]}
              placeholder="hypothesis text, e.g. multi-step reasoning, math, or analysis"
            />
            <.input
              name={"rc[labels][#{i}][class]"}
              type="select"
              options={@classes}
              value={label["class"] || "deep"}
            />
            <.input
              name={"rc[labels][#{i}][min]"}
              type="number"
              step="0.05"
              min="0"
              max="1"
              value={label["min"] || 0.5}
            />
          </div>
        </div>

        <div class="flex flex-wrap items-end gap-3 border-t border-base-content/10 pt-4">
          <div class="grow">
            <.input
              name="preview_prompt"
              value={@preview && @preview.prompt}
              label="Test a prompt — runs the classifier, sends no traffic"
              placeholder="e.g. debug this code"
            />
          </div>
          <.button type="submit" name="intent" value="test">Test</.button>
          <.button type="submit" name="intent" value="save" variant="primary">Save routing</.button>
        </div>
      </.form>

      <div
        :if={@preview}
        class="mt-4 rounded-lg border border-base-content/10 bg-base-200/40 p-4 text-sm"
      >
        <%= case @preview.result do %>
          <% :empty -> %>
            <span class="text-base-content/70">Enter a prompt, then click Test.</span>
          <% {:ok, class, scores} -> %>
            <p>
              Predicted tier: <span class="font-semibold">{class}</span>
              <span class="text-base-content/60">
                · default {@preview.config["default_class"]} · shadow logs only
              </span>
            </p>
            <ul class="mt-2 space-y-1 font-mono text-xs">
              <li :for={l <- @preview.config["labels"]}>
                {if Map.get(scores, l["class"], 0.0) >= l["min"], do: "✓", else: "·"} {l["class"]} ≥ {l[
                  "min"
                ]} — score {Float.round(Map.get(scores, l["class"], 0.0), 3)}
                <span class="text-base-content/50">({l["label"]})</span>
              </li>
            </ul>
          <% :skip -> %>
            <span class="text-base-content/70">No classifiable text in that prompt.</span>
          <% {:error, reason} -> %>
            <span class="text-warning">Classifier error: {inspect(reason)}</span>
        <% end %>
      </div>
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
        <.icon_button
          icon="hero-pencil-square"
          label={"Edit #{a.name}"}
          navigate={~p"/admin/aliases/#{a.id}/edit"}
        />
        <.icon_button
          icon="hero-trash"
          label={"Delete #{a.name}"}
          variant="danger"
          phx-click="delete"
          phx-value-id={a.id}
          data-confirm="Delete this alias?"
        />
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
