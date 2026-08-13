defmodule Airo.Health do
  @moduledoc """
  Per-deployment health, kept in ETS and treated as a **preference signal, not a
  hard gate** (DESIGN §9). Routing prefers `:up` deployments but will still try
  `:unknown`/`:down` ones rather than refuse a freshly-reloaded endpoint.

  A snapshot older than the staleness window (~90s, from orchester) decays to
  `:unknown` so a dead prober can't pin a deployment as forever-healthy.
  `Airo.Health.Prober` writes the snapshots; everyone else reads.
  """

  import Ecto.Query, warn: false

  alias Airo.Config.{Deployment, Provider}
  alias Airo.Health.HealthEvent
  alias Airo.{Logs, Repo, Runtime.Store}

  @staleness_ms 90_000

  @type status :: :up | :down | :unknown
  @type record :: %{status: status(), latency_ms: non_neg_integer() | nil, checked_at: integer()}

  @doc "Record a probe result for a deployment."
  @spec mark(integer(), status(), non_neg_integer() | nil, non_neg_integer()) :: :ok
  def mark(deployment_id, status, latency_ms \\ nil, failures \\ 0)
      when status in [:up, :down, :unknown] do
    record = %{
      status: status,
      latency_ms: latency_ms,
      checked_at: now(),
      # Consecutive failing observations behind this status — see
      # `effective_status/3`. Callers that set a status directly (tests, the
      # serving snapshot) mean it, so the counter starts clean.
      failures: failures
    }

    :ets.insert(Store.health_table(), {deployment_id, record})
    :ok
  end

  @doc """
  Record a deployment health snapshot and persist an event only when effective
  health transitions. Runtime health remains ETS; the DB is incident history.
  """
  @spec mark_deployment(Deployment.t(), Provider.t(), status(), keyword()) :: :ok
  def mark_deployment(%Deployment{} = deployment, %Provider{} = provider, observed, opts \\ [])
      when observed in [:up, :down, :unknown] do
    previous = status(deployment.id)
    latency_ms = opts[:latency_ms]

    {effective, failures} = effective_status(deployment.id, previous, observed)

    :ok = mark(deployment.id, effective, latency_ms, failures)

    if previous != effective do
      record_event(%{
        provider_id: provider.id,
        deployment_id: deployment.id,
        status: effective,
        source: opts[:source] || :probe,
        latency_ms: latency_ms,
        reason: opts[:reason]
      })
    end

    :ok
  end

  # One failure is not an outage. A deployment only goes `:down` after
  # `down_after_failures` consecutive failing observations (`/admin/settings`);
  # until then it keeps whatever it had. Recovery is never delayed — a single
  # `:up` restores it and clears the counter.
  #
  # This is what stops the flapping: health is a *preference* signal and the
  # gateway already fails over per request, so reacting to one slow probe or one
  # failed dispatch bought nothing and wrote a fictional outage that something
  # reversed seconds later. See S24.
  #
  # The threshold is only read on a failure — rare — so the hot path (a
  # successful dispatch) never touches the database for it.
  defp effective_status(_deployment_id, _previous, :up), do: {:up, 0}
  defp effective_status(_deployment_id, _previous, :unknown), do: {:unknown, 0}

  defp effective_status(deployment_id, previous, :down) do
    failures = consecutive_failures(deployment_id) + 1

    if failures >= Airo.Config.down_after_failures() do
      {:down, failures}
    else
      {previous, failures}
    end
  end

  defp consecutive_failures(deployment_id) do
    case get(deployment_id) do
      %{failures: n} when is_integer(n) -> n
      _ -> 0
    end
  end

  # Reasons that describe a *lifecycle* step rather than an incident. A slot the
  # operator asked to reload reports `loading` on its way back up; that is
  # expected, and mirroring it made every reload write two to four lines into
  # the operational log.
  @lifecycle_reasons ~w(loading)

  @doc "Persist one health event."
  def record_event(attrs) do
    result = %HealthEvent{} |> HealthEvent.changeset(attrs) |> Repo.insert()

    # Mirror the transition into the operational log (DESIGN-logging-traceability.md).
    # Leaves health_events and its existing readers untouched; off the hot path.
    #
    # Lifecycle transitions are deliberately *not* mirrored: `health_events`
    # keeps the full sequence as incident history, while `/admin/logs` is what
    # an operator reads and a reload is not an incident. See S24.
    unless lifecycle?(attrs[:reason]) do
      Logs.record(%{
        kind: :health,
        level: if(attrs[:status] == :down, do: :warning, else: :info),
        provider_id: attrs[:provider_id],
        deployment_id: attrs[:deployment_id],
        summary: health_summary(attrs),
        data: %{
          "status" => to_string(attrs[:status]),
          "source" => to_string(attrs[:source]),
          "reason" => attrs[:reason],
          "latency_ms" => attrs[:latency_ms]
        }
      })
    end

    result
  end

  defp lifecycle?(reason) when is_binary(reason), do: reason in @lifecycle_reasons
  defp lifecycle?(_reason), do: false

  defp health_summary(attrs) do
    reason = if attrs[:reason], do: " reason=#{attrs[:reason]}", else: ""

    "health #{attrs[:status]} deployment=#{attrs[:deployment_id]} source=#{attrs[:source]}#{reason}"
  end

  @doc "Recent health transition events, newest first."
  def list_events(limit \\ 100) do
    HealthEvent
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> preload([:provider, :deployment])
    |> Repo.all()
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
