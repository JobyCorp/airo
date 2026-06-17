defmodule AiroWeb.Admin.KeyLive do
  @moduledoc """
  Admin for client keys: mint (raw key shown once), toggle, delete (DESIGN §10).
  """
  use AiroWeb, :live_view

  alias Airo.Config
  alias AiroWeb.CompositeComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Client keys", form: nil, minted: nil)
     |> stream(:keys, Config.list_client_keys())}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  @impl true
  def handle_event("mint", %{"client_key" => params}, socket) do
    attrs = %{
      "name" => params["name"],
      "allowed_aliases" => parse_aliases(params["allowed_aliases"])
    }

    case Config.mint_client_key(attrs) do
      {:ok, key} ->
        {:noreply,
         socket
         |> stream_insert(:keys, key)
         |> assign(form: blank_form(), minted: key.key)
         |> put_flash(:info, "Key minted — copy it now, it won't be shown again.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    key = Config.get_client_key!(id)
    {:ok, key} = Config.update_client_key(key, %{enabled: !key.enabled})
    {:noreply, stream_insert(socket, :keys, key)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    key = Config.get_client_key!(id)
    {:ok, _} = Config.delete_client_key(key)
    {:noreply, stream_delete(socket, :keys, key)}
  end

  def handle_event("dismiss", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/admin/keys")}

  defp apply_action(socket, :index) do
    socket
    |> assign(page_title: "Client keys", form: nil, minted: nil)
    |> stream(:keys, Config.list_client_keys(), reset: true)
  end

  defp apply_action(socket, :new) do
    socket
    |> assign(page_title: "Mint key", form: blank_form(), minted: nil)
  end

  defp blank_form,
    do: to_form(Config.change_client_key(%Config.ClientKey{allowed_aliases: ["*"]}))

  # Comma-separated aliases → list; blank means all ("*").
  defp parse_aliases(nil), do: ["*"]

  defp parse_aliases(string) do
    case string
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> ["*"]
      list -> list
    end
  end

  defp key_header_subtitle(:index), do: "Per-consumer auth, scoped to aliases."
  defp key_header_subtitle(:new), do: "Mint a client key and copy it once."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="keys">
      <div class="mx-auto max-w-7xl space-y-6 px-6 py-8">
        <CompositeComponents.page_header subtitle={key_header_subtitle(@live_action)}>
          <:crumb navigate={~p"/admin/keys"}>Client keys</:crumb>
          <:crumb :if={@live_action == :new}>Mint key</:crumb>
          <:actions :if={@live_action == :index}>
            <.button navigate={~p"/admin/keys/new"} variant="primary">Mint key</.button>
          </:actions>
          <:actions :if={@live_action == :new}>
            <.button size="sm" navigate={~p"/admin/keys"}>Back</.button>
          </:actions>
        </CompositeComponents.page_header>

        <%= if @live_action == :new do %>
          <.key_form form={@form} minted={@minted} />
        <% else %>
          <.key_table keys={@streams.keys} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :minted, :string, default: nil

  defp key_form(assigns) do
    ~H"""
    <div class="space-y-6">
      <.card :if={@minted} variant="elevated">
        <:title>New key — copy it now</:title>
        <p class="break-all font-mono text-sm">{@minted}</p>
        <:actions><.button phx-click="dismiss">Done</.button></:actions>
      </.card>

      <.card :if={!@minted} variant="bordered">
        <:title>Key scope</:title>
        <.form for={@form} id="key-form" phx-submit="mint" class="space-y-4">
          <.input field={@form[:name]} label="Name (e.g. orchester)" />
          <.input
            field={@form[:allowed_aliases]}
            label="Allowed aliases"
            value="*"
            placeholder="* or comma-separated alias names"
          />
          <div class="flex gap-2">
            <.button variant="primary">Mint key</.button>
            <.button type="button" navigate={~p"/admin/keys"}>Cancel</.button>
          </div>
        </.form>
      </.card>
    </div>
    """
  end

  attr :keys, :any, required: true

  defp key_table(assigns) do
    ~H"""
    <.table id="keys" rows={@keys}>
      <:col :let={{_id, k}} label="Name">{k.name}</:col>
      <:col :let={{_id, k}} label="Allowed aliases">{Enum.join(k.allowed_aliases, ", ")}</:col>
      <:col :let={{_id, k}} label="Enabled">{k.enabled}</:col>
      <:action :let={{_id, k}}>
        <.icon_button
          icon="hero-power"
          label={if k.enabled, do: "Disable key", else: "Enable key"}
          phx-click="toggle"
          phx-value-id={k.id}
        />
        <.icon_button
          icon="hero-trash"
          label={"Delete #{k.name}"}
          variant="danger"
          phx-click="delete"
          phx-value-id={k.id}
          data-confirm="Delete this key?"
        />
      </:action>
    </.table>
    """
  end
end
