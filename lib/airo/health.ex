defmodule Airo.Health do
  @moduledoc """
  Per-deployment health, kept in ETS and treated as a **preference signal, not a
  hard gate** (DESIGN §9). Routing prefers `:up` deployments but will still try
  `:unknown`/`:down` ones rather than refuse a freshly-reloaded endpoint.

  A snapshot older than the staleness window (~90s, from orchester) decays to
  `:unknown` so a dead prober can't pin a deployment as forever-healthy.
  `Airo.Health.Prober` writes the snapshots; everyone else reads.
  """

  alias Airo.Runtime.Store

  @staleness_ms 90_000

  @type status :: :up | :down | :unknown
  @type record :: %{status: status(), latency_ms: non_neg_integer() | nil, checked_at: integer()}

  @doc "Record a probe result for a deployment."
  @spec mark(integer(), status(), non_neg_integer() | nil) :: :ok
  def mark(deployment_id, status, latency_ms \\ nil) when status in [:up, :down, :unknown] do
    record = %{status: status, latency_ms: latency_ms, checked_at: now()}
    :ets.insert(Store.health_table(), {deployment_id, record})
    :ok
  end

  @doc "Raw snapshot for a deployment, or `nil` if never probed."
  @spec get(integer()) :: record() | nil
  def get(deployment_id) do
    case :ets.lookup(Store.health_table(), deployment_id) do
      [{^deployment_id, record}] -> record
      [] -> nil
    end
  end

  @doc """
  Effective status: the recorded status, decayed to `:unknown` once the snapshot
  is older than the staleness window or if there is no snapshot.
  """
  @spec status(integer()) :: status()
  def status(deployment_id) do
    case get(deployment_id) do
      nil ->
        :unknown

      %{checked_at: at} when is_integer(at) ->
        if stale?(at), do: :unknown, else: get(deployment_id).status
    end
  end

  @doc "True only when the effective status is `:up`."
  @spec healthy?(integer()) :: boolean()
  def healthy?(deployment_id), do: status(deployment_id) == :up

  @doc "The staleness window in milliseconds."
  def staleness_ms, do: @staleness_ms

  defp stale?(checked_at), do: now() - checked_at > @staleness_ms
  defp now, do: System.monotonic_time(:millisecond)
end
