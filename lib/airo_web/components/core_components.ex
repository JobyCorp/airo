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
  Standard Airo button.

  The default variant is intentionally quiet so table actions, resets, and
  secondary commands do not compete with page-level primary actions.
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)

  attr :class, :any, default: nil
  attr :variant, :string, values: ~w(primary secondary ghost danger), default: "secondary"
  attr :size, :string, values: ~w(sm md lg), default: "md"
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "btn-primary",
      "secondary" =>
        "border border-base-300 bg-base-200/80 text-base-content/80 shadow-none hover:border-base-content/30 hover:bg-base-300 hover:text-base-content",
      "ghost" => "btn-ghost text-base-content/70 hover:text-base-content",
      "danger" => "btn-error btn-soft"
    }

    sizes = %{"sm" => "btn-sm", "md" => nil, "lg" => "btn-lg"}

    assigns =
      assign(assigns, :class_list, [
        "btn",
        Map.fetch!(variants, assigns.variant),
        Map.fetch!(sizes, assigns.size),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link data-component="AiroWeb.CoreComponents.button" class={@class_list} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button data-component="AiroWeb.CoreComponents.button" class={@class_list} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Compact icon-only button for dense table/action surfaces.
  """
  attr :rest, :global,
    include:
      ~w(href navigate patch method download name value disabled type title aria-label phx-click phx-value-id data-confirm)

  attr :class, :any, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :variant, :string, values: ~w(primary secondary ghost danger), default: "ghost"
  attr :size, :string, values: ~w(sm md lg), default: "sm"

  def icon_button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :class_list, [
        "btn btn-square",
        button_variant(assigns.variant),
        button_size(assigns.size),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link
        data-component="AiroWeb.CoreComponents.icon_button"
        class={@class_list}
        title={@label}
        aria-label={@label}
        {@rest}
      >
        <JobyKitCoreComponents.icon name={@icon} class="size-4" />
        <span class="sr-only">{@label}</span>
      </.link>
      """
    else
      ~H"""
      <button
        data-component="AiroWeb.CoreComponents.icon_button"
        class={@class_list}
        title={@label}
        aria-label={@label}
        {@rest}
      >
        <JobyKitCoreComponents.icon name={@icon} class="size-4" />
        <span class="sr-only">{@label}</span>
      </button>
      """
    end
  end

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
  Airo data table.

  Rows use calmer separators instead of zebra blocks. When `row_click` is
  provided, non-action cells receive the click target and hover affordance.

  An optional `:detail` slot turns rows into expand/collapse disclosures:
  clicking a row toggles an inline panel rendered from the slot. Detail mode
  requires `row_id` (for the panel's DOM id), takes precedence over
  `row_click`, and expects a plain list rather than a stream.
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

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div
      data-component="AiroWeb.CoreComponents.table"
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
              <td :if={@action != []} class="w-0 px-4 py-3 align-middle">
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

  defp button_variant("primary"), do: "btn-primary"

  defp button_variant("secondary"),
    do:
      "border border-base-300 bg-base-200/80 text-base-content/80 shadow-none hover:border-base-content/30 hover:bg-base-300 hover:text-base-content"

  defp button_variant("ghost"), do: "btn-ghost text-base-content/70 hover:text-base-content"
  defp button_variant("danger"), do: "btn-error btn-soft"

  defp button_size("sm"), do: "btn-sm"
  defp button_size("md"), do: nil
  defp button_size("lg"), do: "btn-lg"

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
