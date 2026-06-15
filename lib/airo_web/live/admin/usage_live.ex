defmodule AiroWeb.Admin.UsageLive do
  @moduledoc "Read-only usage view: recent records + total cost (DESIGN §10)."
  use AiroWeb, :live_view

  alias Airo.Repo
  alias Airo.Usage

  @impl true
  def mount(_params, _session, socket) do
    records = Usage.list_usage_records(200) |> Repo.preload([:deployment, :client_key])

    {:ok,
     socket
     |> assign(page_title: "Usage", total_cost: Usage.total_cost())
     |> stream(:records, records)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav="usage">
      <div class="mx-auto max-w-6xl space-y-6 px-6 py-8">
        <.header>
          Usage
          <:subtitle>Per-call records and attributed cost.</:subtitle>
        </.header>

        <.card variant="bordered">
          <:eyebrow>Total cost</:eyebrow>
          <:title>{@total_cost}</:title>
          Across all recorded calls.
        </.card>

        <.table id="usage" rows={@streams.records}>
          <:col :let={{_id, r}} label="When">{r.inserted_at}</:col>
          <:col :let={{_id, r}} label="Client">{r.client_key && r.client_key.name}</:col>
          <:col :let={{_id, r}} label="Alias">{r.alias_name}</:col>
          <:col :let={{_id, r}} label="Capability">{r.capability}</:col>
          <:col :let={{_id, r}} label="Model">{r.deployment && r.deployment.model_name}</:col>
          <:col :let={{_id, r}} label="Tokens">{r.tokens_in}/{r.tokens_out}</:col>
          <:col :let={{_id, r}} label="Latency">{r.latency_ms}</:col>
          <:col :let={{_id, r}} label="Outcome">{r.outcome}</:col>
          <:col :let={{_id, r}} label="Cost">{r.cost}</:col>
        </.table>
      </div>
    </Layouts.app>
    """
  end
end
