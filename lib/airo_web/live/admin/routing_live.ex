defmodule AiroWeb.Admin.RoutingLive do
  @moduledoc """
  System classifier settings (S16). One screen to choose the routing engine
  (**local Ortex | remote Infinity**) and its model, the score weighting, the
  tier ladder, and to test a prompt. Routed aliases inherit this — they only
  toggle `router`/`router_mode`. See DESIGN-routing-settings.md.
  """
  use AiroWeb, :live_view

  alias Airo.Config
  alias Airo.Config.{Deployment, RoutingSetting}
  alias Airo.Routing.{Classifier, LocalClassifier}
  alias AiroWeb.CompositeComponents

  # complexity_dims order (weighting knob for the ortex backend).
  @dims ~w(creativity reasoning constraint domain_knowledge contextual_knowledge num_few_shots)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Routing",
       dims: @dims,
       backends: [{"Local — on-CPU ONNX (Ortex)", "ortex"}, {"Remote — Infinity NLI", "infinity"}],
       input_modes: [{"Last user message", "last_user"}, {"All turns", "all"}],
       classes: Enum.map(Deployment.classes(), &to_string/1),
       classify_aliases: classify_alias_names(),
       models: model_options(),
       preview: nil
     )
     |> load(Config.get_routing_setting())}
  end

  defp load(socket, %RoutingSetting{} = setting), do: assign(socket, setting: setting)

  @impl true
  def handle_event("submit", %{"intent" => "test"} = params, socket), do: run_test(params, socket)

  def handle_event("submit", params, socket) do
    case Config.update_routing_setting(attrs(params["rs"] || %{})) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(setting: setting, models: model_options(), preview: nil)
         |> put_flash(:info, "Routing settings saved.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid: #{errors(changeset)}")}
    end
  end

  # "Test" — preview the *current form* config (unsaved) on one prompt, no traffic.
  defp run_test(params, socket) do
    prompt = String.trim(params["preview_prompt"] || "")

    config =
      %RoutingSetting{}
      |> RoutingSetting.changeset(attrs(params["rs"] || %{}))
      |> Ecto.Changeset.apply_changes()
      |> Config.routing_config_from()

    result =
      if prompt == "",
        do: :empty,
        else:
          Classifier.classify(config, %{"messages" => [%{"role" => "user", "content" => prompt}]})

    {:noreply, assign(socket, preview: %{prompt: prompt, result: result, config: config})}
  end

  ## Form params → changeset attrs

  defp attrs(rs) do
    %{
      backend: rs["backend"] || "infinity",
      classifier: blank_to_nil(rs["classifier"]),
      model: blank_to_nil(rs["model"]),
      input: rs["input"] || "last_user",
      default_class: blank_default(rs["default_class"], "edge"),
      timeout_ms: to_int(rs["timeout_ms"], 200),
      hypothesis_template: blank_default(rs["hypothesis_template"], "This request requires {}."),
      score: weights(rs["weights"]),
      labels: labels(rs["labels"])
    }
  end

  defp weights(w) when is_map(w) do
    for {dim, raw} <- w, dim in @dims, (v = to_float(raw)) && v > 0.0, into: %{}, do: {dim, v}
  end

  defp weights(_), do: %{}

  defp labels(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
    |> Enum.map(fn {_i, r} ->
      %{
        "label" => blank_to_nil(r["label"]),
        "class" => String.trim(r["class"] || ""),
        "min" => to_float(r["min"]) || 0.5
      }
    end)
    |> Enum.reject(&(&1["class"] == ""))
  end

  defp labels(_), do: []

  ## Helpers

  defp classify_alias_names do
    Config.list_aliases()
    |> Enum.filter(&(&1.capability == :classify))
    |> Enum.map(&{&1.name, &1.name})
  end

  defp model_options do
    Enum.map(LocalClassifier.installed_models(), fn %{name: n, status: s} ->
      {"#{n} (#{s})", n}
    end)
  end

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(_), do: nil

  defp blank_default(v, default), do: blank_to_nil(v) || default

  defp to_int(v, default) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_float(v) do
    case Float.parse(to_string(v)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        s: assigns.setting,
        weight_of: fn dim -> assigns.setting.score[dim] end,
        label_rows: Enum.with_index((assigns.setting.labels || []) ++ [%{}, %{}])
      )

    ~H"""
    <Layouts.app flash={@flash} active_nav="routing">
      <div class="mx-auto max-w-4xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle="The system classifier — how Airo grades prompts for tier routing. Routed aliases inherit this; they only toggle routing on/off and shadow/enforce.">
          <:crumb>Routing</:crumb>
        </CompositeComponents.page_header>

        <.form for={%{}} id="routing-form" phx-submit="submit" class="space-y-6">
          <.card variant="bordered">
            <:eyebrow>Engine</:eyebrow>
            <:title>Classifier model</:title>
            <div class="grid gap-4 sm:grid-cols-2">
              <.input
                name="rs[backend]"
                type="select"
                label="Engine"
                options={@backends}
                value={to_string(@s.backend)}
              />
              <.input
                name="rs[input]"
                type="select"
                label="Text to classify"
                options={@input_modes}
                value={to_string(@s.input)}
              />
            </div>

            <div class="mt-4 space-y-4 border-t border-base-content/10 pt-4">
              <p class="text-sm font-medium">Local (Ortex)</p>
              <.input
                name="rs[model]"
                type="select"
                label="Model (priv/models/)"
                options={@models}
                value={@s.model}
                prompt={
                  if @models == [],
                    do: "No models installed — run mix airo.fetch_model",
                    else: "Select a model"
                }
              />
              <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
                <.input
                  :for={dim <- @dims}
                  name={"rs[weights][#{dim}]"}
                  type="number"
                  step="0.05"
                  min="0"
                  max="1"
                  label={dim}
                  value={@weight_of.(dim)}
                />
              </div>
              <p class="text-xs text-base-content/60">
                Weights combine the model's complexity dimensions into the routing score (all blank ⇒ the model's own "overall").
              </p>
            </div>

            <div class="mt-4 space-y-4 border-t border-base-content/10 pt-4">
              <p class="text-sm font-medium">Remote (Infinity)</p>
              <.input
                name="rs[classifier]"
                type="select"
                label="Classifier alias (:classify)"
                options={@classify_aliases}
                value={@s.classifier}
                prompt="Select a :classify alias"
              />
              <.input
                name="rs[hypothesis_template]"
                label="Hypothesis template ({} → each label)"
                value={@s.hypothesis_template}
              />
            </div>
          </.card>

          <.card variant="bordered">
            <:eyebrow>Tier ladder</:eyebrow>
            <:title>Thresholds</:title>
            <div class="grid gap-4 sm:grid-cols-2">
              <.input
                name="rs[default_class]"
                type="select"
                label="Default tier (no match)"
                options={@classes}
                value={@s.default_class}
              />
              <.input name="rs[timeout_ms]" type="number" label="Timeout (ms)" value={@s.timeout_ms} />
            </div>
            <p class="mt-4 text-sm font-medium">
              Highest tier first; the first whose score ≥ its min wins. Clear a row's tier to remove it.
              <span class="text-base-content/60">
                (Label text is the NLI hypothesis — Infinity only.)
              </span>
            </p>
            <div
              :for={{label, i} <- @label_rows}
              class="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-[1fr_9rem_7rem]"
            >
              <.input
                name={"rs[labels][#{i}][label]"}
                value={label["label"]}
                placeholder="hypothesis text (Infinity only)"
              />
              <.input
                name={"rs[labels][#{i}][class]"}
                type="select"
                options={@classes}
                value={label["class"]}
                prompt="— (blank to remove)"
              />
              <.input
                name={"rs[labels][#{i}][min]"}
                type="number"
                step="0.05"
                min="0"
                max="1"
                value={label["min"] || 0.5}
              />
            </div>
          </.card>

          <.card variant="bordered">
            <:eyebrow>Test</:eyebrow>
            <:title>Try a prompt</:title>
            <div class="flex flex-wrap items-end gap-3">
              <div class="grow">
                <.input
                  name="preview_prompt"
                  value={@preview && @preview.prompt}
                  label="Runs the classifier on the current (unsaved) settings — sends no traffic"
                  placeholder="e.g. refactor the auth module across three files"
                />
              </div>
              <.button type="submit" name="intent" value="test">Test</.button>
              <.button type="submit" name="intent" value="save" variant="primary">Save</.button>
            </div>

            <div
              :if={@preview}
              class="mt-4 rounded-lg border border-base-content/10 bg-base-200/40 p-4 text-sm"
            >
              <%= case @preview.result do %>
                <% :empty -> %>
                  <span class="text-base-content/70">Enter a prompt, then click Test.</span>
                <% {:ok, class, scores} -> %>
                  <p>Predicted tier: <span class="font-semibold">{class}</span></p>
                  <p :if={scores["_task"]} class="mt-1 text-xs text-base-content/60">
                    task: {scores["_task"]} · overall: {scores["_overall"]}
                  </p>
                  <ul class="mt-2 space-y-1 font-mono text-xs">
                    <li :for={l <- @preview.config.labels}>
                      {if Map.get(scores, l.class, 0.0) >= l.min, do: "✓", else: "·"} {l.class} ≥ {l.min} — score {Float.round(
                        Map.get(scores, l.class, 0.0),
                        3
                      )}
                    </li>
                  </ul>
                <% :skip -> %>
                  <span class="text-base-content/70">No classifiable text in the prompt.</span>
                <% {:error, reason} -> %>
                  <span class="text-error">
                    Classifier error: {inspect(reason)} (routing would fail open).
                  </span>
              <% end %>
            </div>
          </.card>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
