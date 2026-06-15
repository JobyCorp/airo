defmodule AiroWeb.Admin.KeyLive do
  @moduledoc """
  Admin for client keys: mint (raw key shown once), toggle, delete (DESIGN §10).
  """
  use AiroWeb, :live_view

  alias Airo.Config

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Client keys", form: blank_form(), minted: nil)
     |> stream(:keys, Config.list_client_keys())}
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

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, minted: nil)}

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="keys">
      <div class="mx-auto max-w-6xl space-y-6 px-6 py-8">
        <.header>
          Client keys
          <:subtitle>Per-consumer auth, scoped to aliases.</:subtitle>
        </.header>

        <.card :if={@minted} variant="elevated">
          <:title>New key — copy it now</:title>
          <p class="break-all font-mono text-sm">{@minted}</p>
          <:actions><.button phx-click="dismiss">Done</.button></:actions>
        </.card>

        <.card variant="bordered">
          <:title>Mint a key</:title>
          <.form for={@form} phx-submit="mint" class="space-y-4">
            <.input field={@form[:name]} label="Name (e.g. orchester)" />
            <.input
              field={@form[:allowed_aliases]}
              label="Allowed aliases"
              value="*"
              placeholder="* or comma-separated alias names"
            />
            <.button variant="primary">Mint key</.button>
          </.form>
        </.card>

        <.table id="keys" rows={@streams.keys}>
          <:col :let={{_id, k}} label="Name">{k.name}</:col>
          <:col :let={{_id, k}} label="Allowed aliases">{Enum.join(k.allowed_aliases, ", ")}</:col>
          <:col :let={{_id, k}} label="Enabled">{k.enabled}</:col>
          <:action :let={{_id, k}}>
            <.button size="sm" phx-click="toggle" phx-value-id={k.id}>
              {if k.enabled, do: "Disable", else: "Enable"}
            </.button>
            <.button size="sm" phx-click="delete" phx-value-id={k.id} data-confirm="Delete this key?">
              Delete
            </.button>
          </:action>
        </.table>
      </div>
    </Layouts.app>
    """
  end
end
