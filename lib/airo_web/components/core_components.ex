defmodule AiroWeb.CoreComponents do
  @moduledoc """
  Airo-specific core wrappers layered on top of daisyUI primitives.

  JobyKit provides the baseline wrapper contract. This module hosts local
  variants where Airo needs different interaction hierarchy than the shared
  defaults.
  """

  use Phoenix.Component

  alias JobyKit.CoreComponents, as: JobyKitCoreComponents
  alias Phoenix.LiveView.JS

  @doc """
  Checkbox group for small enum arrays.

  Use this when a native multi-select would hide available choices or require
  keyboard-specific selection behavior.
  """
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :label, :string, default: nil
  attr :options, :list, required: true
  attr :value, :any, default: nil
  attr :errors, :list, default: []
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form required)

  def checkbox_group(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(:field, nil)
    |> assign(:id, assigns.id || field.id)
    |> assign(:name, assigns.name || field.name <> "[]")
    |> assign(:value, assigns.value || field.value)
    |> assign(:errors, Enum.map(errors, &JobyKitCoreComponents.translate_error/1))
    |> checkbox_group()
  end

  def checkbox_group(assigns) do
    base_id = assigns.id || checkbox_group_id(assigns.name)

    assigns =
      assigns
      |> assign(:id, base_id)
      |> assign(:selected_values, selected_values(assigns.value))
      |> assign(:normalized_options, normalize_checkbox_options(assigns.options, base_id))

    ~H"""
    <fieldset
      id={@id <> "-group"}
      data-component="AiroWeb.CoreComponents.checkbox_group"
      class={["fieldset mb-2", @class]}
      {@rest}
    >
      <legend :if={@label} class="label mb-2">{@label}</legend>
      <input type="hidden" name={@name} value="" disabled={@rest[:disabled]} form={@rest[:form]} />
      <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        <label
          :for={option <- @normalized_options}
          for={option.id}
          class={[
            "group flex cursor-pointer items-center gap-3 rounded-lg border px-3 py-3 text-sm transition-colors duration-150",
            option.value in @selected_values &&
              "border-primary/60 bg-primary/10 text-base-content shadow-sm",
            option.value not in @selected_values &&
              "border-base-300 bg-base-100/40 text-base-content/75 hover:border-base-content/25 hover:bg-base-200/50"
          ]}
        >
          <input
            type="checkbox"
            id={option.id}
            name={@name}
            value={option.value}
            checked={option.value in @selected_values}
            class="checkbox checkbox-sm"
            disabled={@rest[:disabled]}
            form={@rest[:form]}
          />
          <span class="font-medium">{option.label}</span>
        </label>
      </div>
      <p :for={msg <- @errors} class="mt-1.5 flex items-center gap-2 text-sm text-error">
        <JobyKitCoreComponents.icon name="hero-exclamation-circle" class="size-5" />
        {msg}
      </p>
    </fieldset>
    """
  end

  @doc """
  A `<.table>` on Airo's data surface.

      <.data_table id="providers" rows={@providers}>
        <:col :let={p} label="Name">{p.name}</:col>
        <:empty>No providers yet.</:empty>
      </.data_table>

  The kit's `table/1` renders a bare `<table>` — no container, so it has
  nowhere to hang a border, a radius, or `overflow-x-auto`. Every other block
  in this admin sits on `rounded-lg border-base-300 bg-base-100/35`; a table
  floating on the page background is the one thing that doesn't, and on a
  narrow viewport it also has no way to scroll instead of overflowing.

  Zebra is off. Airo's rows are separated by a hairline rather than alternating
  fills: these tables carry status pills and mono identifiers whose own tints
  have to stay legible, and striping competes with them for the same signal.
  Pass `zebra` if a particular table really wants it.

  Slots forward to the kit component, so everything `table/1` accepts —
  `row_click`, `row_id`, `size`, `:empty` — works unchanged.
  """
  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :zebra, :boolean, default: false
  attr :class, :any, default: nil, doc: "Utilities for the surface, not the table."

  # Declared rather than swept up by `:rest`, which only carries globals.
  attr :table_id, :string, default: nil
  attr :size, :string, values: ~w(xs sm md lg), default: "md"
  attr :row_id, :any, default: nil
  attr :row_click, :any, default: nil
  attr :row_item, :any, default: &Function.identity/1
  attr :rest, :global

  slot :col, required: true do
    attr :label, :string
  end

  slot :action
  slot :empty

  def data_table(assigns) do
    ~H"""
    <div
      data-component="AiroWeb.CoreComponents.data_table"
      class={["overflow-x-auto rounded-lg border border-base-300 bg-base-100/35", @class]}
    >
      <JobyKitCoreComponents.table
        id={@id}
        table_id={@table_id}
        rows={@rows}
        zebra={@zebra}
        size={@size}
        row_id={@row_id}
        row_click={@row_click}
        row_item={@row_item}
        {@rest}
      >
        <:col :let={row} :for={col <- @col} label={col[:label]}>
          {render_slot(col, row)}
        </:col>
        <:action :let={row} :for={action <- @action}>
          {render_slot(action, row)}
        </:action>
        <:empty :for={empty <- @empty}>
          {render_slot(empty)}
        </:empty>
      </JobyKitCoreComponents.table>
    </div>
    """
  end

  @doc """
  Data table whose rows expand into an inline detail panel.

  **Use `<.table>` (JobyKit) unless you need the disclosure.** This exists
  only for the `:detail` slot, which the kit's table has no equivalent for;
  everything else here duplicates it. Clicking a row toggles a panel rendered
  from the slot. Detail mode requires `row_id` (for the panel's DOM id), takes
  precedence over `row_click`, and expects a plain list rather than a stream.

  Named apart from `table/1` on purpose: shadowing the kit's component would
  silently divert every `<.table>` call site here and cut them off from kit
  fixes — the failure `mix joby_kit.lint`'s `:forked_wrapper` rule exists to
  catch.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :class, :any, default: nil
  attr :row_id, :any, default: nil
  attr :row_click, :any, default: nil
  attr :row_item, :any, default: &Function.identity/1
  attr :rest, :global

  slot :col, required: true do
    attr :label, :string
  end

  slot :action
  slot :detail

  def disclosure_table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div
      data-component="AiroWeb.CoreComponents.disclosure_table"
      class="overflow-x-auto rounded-lg border border-base-300 bg-base-100/35"
      {@rest}
    >
      <table class={["w-full border-separate border-spacing-0 text-sm", @class]}>
        <thead>
          <tr class="border-b border-base-300 bg-base-200/20 text-left">
            <th :if={@detail != []} class="w-8 py-3 pl-4">
              <span class="sr-only">Expand</span>
            </th>
            <th
              :for={col <- @col}
              class="px-4 py-3 text-xs font-semibold uppercase tracking-wide text-base-content/55"
            >
              {col[:label]}
            </th>
            <th :if={@action != []} class="w-0 px-4 py-3">
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
          class="divide-y divide-base-300/65"
        >
          <%= for row <- @rows do %>
            <tr
              id={@row_id && @row_id.(row)}
              data-expanded={@detail != [] && "false"}
              class={[
                "group transition-colors duration-150",
                (@row_click || @detail != []) && "hover:bg-base-200/45",
                !(@row_click || @detail != []) && "hover:bg-base-200/20"
              ]}
            >
              <td
                :if={@detail != []}
                phx-click={toggle_detail(@row_id.(row))}
                class="w-8 cursor-pointer py-3 pl-4 align-middle"
              >
                <JobyKitCoreComponents.icon
                  name="hero-chevron-right"
                  class="size-3.5 text-base-content/40 transition-transform duration-150 group-data-[expanded=true]:rotate-90"
                />
              </td>
              <td
                :for={col <- @col}
                phx-click={row_cell_click(@detail, @row_click, @row_id, row)}
                class={[
                  "px-4 py-3 align-middle text-base-content/80",
                  (@row_click || @detail != []) && "cursor-pointer"
                ]}
              >
                {render_slot(col, @row_item.(row))}
              </td>
              <!-- `whitespace-nowrap` because `w-0` makes the cell report
                   min-content, and wrappable action text then lets it
                   under-report and paint past the table edge. Carried over
                   from the kit's 0.2.1 table fix, which this fork missed. -->
              <td
                :if={@action != []}
                data-table-actions
                class="w-0 whitespace-nowrap px-4 py-3 align-middle"
              >
                <div class="flex justify-end gap-1 opacity-80 transition-opacity group-hover:opacity-100">
                  <%= for action <- @action do %>
                    {render_slot(action, @row_item.(row))}
                  <% end %>
                </div>
              </td>
            </tr>
            <tr :if={@detail != []} id={"#{@row_id.(row)}-detail"} class="hidden">
              <td
                colspan={length(@col) + 1 + if(@action != [], do: 1, else: 0)}
                class="bg-base-200/15 px-6 py-4"
              >
                {render_slot(@detail, @row_item.(row))}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp toggle_detail(row_id) do
    JS.toggle(to: "##{row_id}-detail", display: "table-row")
    |> JS.toggle_attribute({"data-expanded", "true", "false"}, to: "##{row_id}")
  end

  defp row_cell_click(detail, row_click, row_id, row) do
    cond do
      detail != [] -> toggle_detail(row_id.(row))
      row_click -> row_click.(row)
      true -> nil
    end
  end

  defp normalize_checkbox_options(options, base_id) do
    Enum.map(options, fn
      {label, value} ->
        normalized_value = to_string(value)

        %{
          id: "#{base_id}-#{safe_dom_id(normalized_value)}",
          label: to_string(label),
          value: normalized_value
        }

      value ->
        normalized_value = to_string(value)

        %{
          id: "#{base_id}-#{safe_dom_id(normalized_value)}",
          label: humanize_option(value),
          value: normalized_value
        }
    end)
  end

  defp selected_values(nil), do: MapSet.new()

  defp selected_values(values) when is_list(values),
    do: values |> Enum.map(&to_string/1) |> MapSet.new()

  defp selected_values(value), do: MapSet.new([to_string(value)])

  defp checkbox_group_id(nil), do: "checkbox-group"

  defp checkbox_group_id(name) do
    name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
    |> then(fn
      "" -> "checkbox-group"
      id -> id
    end)
  end

  defp safe_dom_id(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp humanize_option(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
