defmodule Airo.Runtime.Store do
  @moduledoc """
  Owns Airo's runtime ETS tables — state that is fast-changing and derivable, so
  it lives outside the config/Postgres plane (DESIGN §8: "health is runtime, not
  config").

  - `:airo_health` — per-deployment health snapshots (`Airo.Health`).
  - `:airo_routing` — round-robin counters per alias (`Airo.Routing`).

  Tables are `:public` with read/write concurrency so callers hit ETS directly
  without serializing through this process; the GenServer exists only to own the
  tables and keep them alive for the node's lifetime.
  """
  use GenServer

  @health :airo_health
  @routing :airo_routing

  def health_table, do: @health
  def routing_table, do: @routing

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    opts = [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]
    :ets.new(@health, opts)
    :ets.new(@routing, opts)
    {:ok, %{}}
  end
end
